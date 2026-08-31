# 106.3 Accesibilidad

> **Examen:** LPIC-1 102-500 · **Tema 106:** Interfaces de usuario y escritorios · **Objetivo 106.3:** Accesibilidad · **Peso oficial:** 1
>
> **Términos del objetivo (v5.0):** Sticky/Repeat Keys · Slow/Bounce/Toggle Keys · Mouse Keys · Temas de escritorio de alto contraste / letra grande · Lector de pantalla · Línea braille · Magnificador de pantalla · Teclado en pantalla · Gestos (usados en el login, p. ej. GDM) · Orca · GOK · emacspeak

---

## 1. Motivación: la accesibilidad como propiedad de producción, no como preferencia de escritorio

### 1.1 El problema arquitectónico

La accesibilidad en Linux suele enseñarse como "marcá algunas casillas en Configuración". Ese encuadre está mal para cualquiera que opere una flota, y produce tres fallas concretas en producción:

**Falla 1 — el estado vive donde la gestión de configuración no puede verlo.**
La configuración de accesibilidad de un usuario está dispersa en al menos cinco almacenes independientes, con distintos ciclos de vida, distintos dueños y sin transacción común:

| Almacén | Alcance | ¿Sobrevive al reinicio? | ¿Sobrevive a `setxkbmap`? | ¿Gestionado por CM? |
|---|---|---|---|---|
| Base de datos de usuario de `dconf` (`~/.config/dconf/user`) | por usuario, por sesión | sí | sí | solo mediante capas `system-db` |
| Controles AccessX de XKB (estado del servidor X) | por servidor X | **no** | **no** — se resetea en silencio | no |
| `/sys/accessibility/speakup/*` | por arranque, global | **no** | n/a | vía `sysfs.d` / opciones de módulo |
| `/etc/brltty.conf` + udev | global | sí | n/a | sí |
| `~/.config/speech-dispatcher/` | por usuario | sí | n/a | rara vez |

Ansible converge `/etc`. Nada de lo anterior salvo `/etc/brltty.conf` vive ahí. Por eso los ajustes de a11y son la fuente más común de deriva silenciosa en flotas de escritorios gestionados: la imagen cumple en el momento de la compilación y diverge dentro del primer login.

**Falla 2 — la accesibilidad desaparece justo en la ruta de recuperación.**
La cadena de arranque es `firmware → GRUB → initramfs → shell de emergencia → systemd → gestor de pantalla → sesión`. La lectura de pantalla está disponible en la *última* etapa en la mayoría de las distribuciones. Cada etapa anterior — precisamente las etapas a las que llegás cuando algo está roto — es muda y sin braille salvo que se la haya diseñado deliberadamente. Un operador que depende del habla puede administrar una máquina sana y no puede administrar una rota. Eso es un punto único de falla con una persona adentro.

**Falla 3 — nada lo testea.**
No existe un `curl -f` para "el lector de pantalla sigue hablando después de actualizar el toolkit". Una migración a GTK4, un cambio de Wayland por defecto, un `NO_AT_BRIDGE=1` heredado de una imagen base de contenedor, o un Flatpak empaquetado sin `--socket=accessibility` rompen cada uno todo el stack asistivo con una firma de **cero errores, cero logs, exit-code-0**. La regresión la descubre un usuario, en producción, normalmente durante un incidente.

### 1.2 Por qué esto pertenece a un plan de estudios de SRE

* **Regulatorio**: EN 301 549 (obligatoria para la contratación pública en la UE), Section 508 (federal en EE. UU.) y WCAG 2.2 como línea base normativa referenciada. Una golden image no conforme es un bloqueo de contratación, no un ticket.
* **Fiabilidad**: definí la *ruta de arranque accesible* como una propiedad testeada y versionada de la imagen, del mismo modo que testeás que `sshd` levante. Si tu runbook de DR asume un operador vidente en una consola física, tu plan de DR tiene una dependencia no testeada.
* **Radio de impacto**: la configuración de a11y se entrega por los mismos mecanismos que todo lo demás (bases de datos de sistema de dconf, unidades systemd, udev, línea de comandos del kernel). Equivocarse — por ejemplo, bloquear una clave de dconf que un usuario debe poder alternar — es una denegación de acceso a la máquina *a nivel de flota* para los usuarios afectados.

### 1.3 Los servidores también tienen superficie de accesibilidad

En infraestructura headless el stack de escritorio es irrelevante; lo que importa es:

* la **consola virtual de Linux** (VT) — legible por `speakup`/`fenrir`/`brltty` a través de `/dev/vcsa*`;
* la **consola serie** (`console=ttyS0,115200n8`) y el Serial-over-LAN del BMC — la única ruta que sobrevive a una GPU muerta, y la ruta que una terminal braille remota puede consumir;
* la **salida de las herramientas de ops** — respetá `NO_COLOR`, nunca codifiques significado solo con color, mantené disponible la salida `--json` para TUIs y lectores de pantalla.

---

## 2. Arquitectura del stack de accesibilidad de Linux

Existen dos stacks. Casi no comparten nada. Saber en cuál estás determina cada paso de depuración.

```
┌─────────────────────────────── GRAPHICAL STACK ────────────────────────────────┐
│                                                                                │
│  Orca (screen reader, Python)     Magnifier (mutter/KWin)   OSK (shell/wvkbd)  │
│        │              │                      │                     │           │
│        │ AT-SPI2      │ BrlAPI               │ compositor API      │ input     │
│        ▼              ▼                      ▼                     ▼           │
│  ┌───────────────────────────┐   ┌────────┐          ┌────────────────────┐    │
│  │ at-spi2-registryd         │   │ brltty │          │ XTEST (X11) /      │    │
│  │ on the a11y D-Bus         │   │ (a2)   │          │ virtual-keyboard,  │    │
│  │ (org.a11y.Bus)            │   └────────┘          │ libei (Wayland)    │    │
│  └───────────▲───────────────┘                       └────────────────────┘    │
│              │ exposes accessible object tree                                  │
│   ┌──────────┴────────────┬──────────────────┬─────────────────┐               │
│   │ GTK4 (native AT-SPI)  │ GTK3 (atk-bridge)│ Qt5/6 (qspi)    │ Java (atk)    │
│   └───────────────────────┴──────────────────┴─────────────────┘               │
│              │ speech                                                          │
│              ▼                                                                 │
│   speech-dispatcher ──► sd_espeak-ng / sd_festival / sd_pico / RHVoice          │
│                    └──► PipeWire / PulseAudio / ALSA                            │
│                                                                                │
│  Keyboard/pointer filtering: XKB AccessX controls (X11) │ compositor (Wayland)  │
└────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────── CONSOLE STACK ─────────────────────────────────┐
│  speakup (kernel, drivers/accessibility/speakup since Linux 5.10)               │
│      ├── speakup_soft ──► /dev/softsynth ──► espeakup ──► espeak-ng ──► ALSA    │
│      └── speakup_<hw>  ──► hardware synth on a serial port                      │
│  fenrir / yasr (userspace)  ──► reads /dev/vcsa*  ──► speech-dispatcher         │
│  brltty (screen driver "lx") ──► /dev/vcsa*  ──► braille display over USB/BT    │
│  Rendering: setfont / vconsole.conf / fbcon=font:TER16x32                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 AT-SPI2 — el bus del que depende todo lo gráfico

AT-SPI2 es un protocolo **D-Bus** (el AT-SPI1 basado en CORBA está muerto hace mucho). Su dirección se publica en un bus dedicado, descubrible de dos maneras:

* `org.a11y.Bus.GetAddress` en el bus de sesión (canónica), y
* la propiedad `AT_SPI_BUS` en la ventana raíz de X11 (heredada, solo X11).

Los toolkits registran sus árboles de widgets en ese bus. El demonio de registro (`at-spi2-registryd`) hace de intermediario; Orca es apenas un cliente. Consecuencias que importan operativamente:

* **Tiene alcance de sesión.** `ssh -X` reenvía el *renderizado*, no el bus de a11y. Una aplicación reenviada remotamente es invisible para el lector de pantalla local. Los escritorios accesibles remotos deben ejecutar todo el stack del lado del servidor (VNC/RDP/xrdp) y transmitir el audio de vuelta.
* **Los sandboxes lo rompen.** Flatpak necesita `--socket=accessibility`; los contenedores necesitan el socket del bus de sesión montado por bind y `NO_AT_BRIDGE` sin definir.
* **GTK3 está condicionado por un ajuste**, GTK4 no:

| Toolkit | Puente | Condición de activación |
|---|---|---|
| GTK 2 | módulo `gail` + `atk-bridge` | `GTK_MODULES=gail:atk-bridge` |
| GTK 3 | `atk-bridge` | `org.gnome.desktop.interface toolkit-accessibility=true` (X11); deshabilitado por `NO_AT_BRIDGE=1` |
| GTK 4 | implementación nativa de AT-SPI | siempre activo, sin conmutador |
| Qt 5 / Qt 6 | plugin `libqspiaccessiblebridge` | `QT_ACCESSIBILITY=1` (o `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`) |
| Java (Swing) | Java ATK Wrapper | `assistive_technologies=org.GNOME.Accessibility.AtkWrapper` en `accessibility.properties` |
| Electron/Chromium | autodetecta AT-SPI | `--force-renderer-accessibility` para forzarlo |

---

## 3. Comparativas técnicas y compromisos

### 3.1 Lectores de pantalla

| Lector | Capa | Lee | ¿Funciona antes de X? | Braille | Mantenido | Rol en producción |
|---|---|---|---|---|---|---|
| **Orca** | GUI, cliente AT-SPI2 | árbol de objetos accesibles | no | vía BrlAPI + liblouis | sí (GNOME) | el único lector GUI completo |
| **speakup + espeakup** | kernel + demonio | búfer de texto de la VT | **sí** (temprano, si está compilado en el kernel) | no | sí (mainline) | consola/rescate; revisión por VT |
| **fenrir** | espacio de usuario, `/dev/vcsa` | búfer de texto de la VT | tras `local-fs` | sí (BrlAPI) | sí | lector de consola moderno, programable |
| **yasr** | envoltorio de pty | la pty de un solo programa | sí | no | prácticamente muerto | heredado / último recurso |
| **BRLTTY** | demonio | VT (`lx`) o AT-SPI (`a2`) | sí | **propósito principal** | sí | braille en todas partes + habla opcional |
| **emacspeak** | aplicación | solo búferes de Emacs | sí (dentro de Emacs) | vía BRLTTY | sí | "escritorio de audio" para usuarios centrados en Emacs |

**El compromiso que decide el diseño:** `speakup` lee el *búfer de texto*, así que funciona en un sistema roto, en modo monousuario y durante un `fsck` — pero no puede describir un widget, un rol ni un cambio de foco. Orca entiende la semántica pero requiere una sesión completa. Una imagen de estación de trabajo conforme necesita **ambos**; ninguno sustituye al otro.

### 3.2 Motores de síntesis de voz

| Sintetizador | Módulo de speech-dispatcher | Latencia | Calidad | Huella | Offline | Notas |
|---|---|---|---|---|---|---|
| **espeak-ng** | `sd_espeak-ng` | la más baja (formantes) | robótica | ~5 MB | sí | por defecto; el único suficientemente rápido para navegación ágil |
| **Festival** | `sd_festival` | media | mejor prosodia | ~100 MB+ | sí | voces por difonos / selección de unidades |
| **Pico (SVOX)** | `sd_pico` | baja | buena, pocos idiomas | ~10 MB | sí | conjunto de idiomas limitado |
| **RHVoice** | `sd_rhvoice` | media | muy buena | ~100 MB/voz | sí | fuerte cobertura de ru/uk/otros |
| **TTS en la nube** | módulo a medida | RTT de red | la mejor | n/a | **no** | descalificado: dependencia de red en la ruta de recuperación |

Los usuarios experimentados de lectores de pantalla habitualmente usan espeak-ng a 400–600 palabras/min; los motores "que suenan mejor" y agregan 200 ms de latencia por enunciado son activamente peores para ellos. **No "actualices" el sintetizador de un usuario sin preguntar.**

### 3.3 X11 vs Wayland — matriz de capacidades

| Capacidad | X11 | Wayland (GNOME/mutter) | Wayland (wlroots, p. ej. sway) |
|---|---|---|---|
| Árbol de objetos AT-SPI2 | sí | sí (D-Bus, independiente del compositor) | sí, pero pocos clientes lo alimentan |
| Capturas de teclas del lector de pantalla | XGrabKey | provistas por mutter | **sin mecanismo estándar** |
| Entrada sintética (OSK, emulación de ratón) | XTEST | `virtual-keyboard-v1`, portales, **libei** | `virtual-keyboard-v1`/`wtype` |
| Magnificación de pantalla | externa (`xzoom`, compositor) | integrada en el compositor | específica del compositor / ausente |
| Captura de pantalla para herramientas tipo OCR | XGetImage (cualquier cliente) | solo mediada por portales | solo mediada por portales |
| Sticky/Slow/Bounce/Mouse Keys | **AccessX de XKB en el servidor X** | implementadas por el compositor (mismas claves gsettings) | mayormente ausentes |
| `xkbset`, `xdotool`, `xev` | funcionan | **solo para clientes XWayland** | no funcionan |

**Consecuencia arquitectónica:** X11 le dio omnipotencia a cada cliente, lo que es un desastre de seguridad y una comodidad para la accesibilidad. Wayland cerró el agujero, y la tecnología asistiva tuvo que reimplementarse *dentro* de los compositores. Hoy GNOME sobre Wayland es una plataforma de a11y completa; los compositores wlroots minimalistas no lo son. `libei`/`xdg-desktop-portal` es la ruta estándar convergente para la emulación de entrada, pero **si un usuario depende de un lector de pantalla, GNOME (Wayland o X11) o Plasma es la elección soportada — no un compositor wlroots de mosaico.**

### 3.4 Teclados en pantalla

| OSK | Servidor gráfico | Método de entrada | Estado | Caso de uso |
|---|---|---|---|---|
| **OSK de GNOME Shell** | X11 + Wayland | interno del compositor | mantenido | por defecto; usuarios táctiles y de solo puntero |
| **GOK** (GNOME On-screen Keyboard) | X11 | XTEST + escaneo AT-SPI | **muerto** (~2012), retirado de las distros | **solo término de examen** — conoce el escaneo por acceso con conmutador |
| **Caribou** | X11 + Wayland | XTEST/IM | obsoleto, absorbido por Shell | GNOME heredado |
| **Onboard** | X11 | XTEST | sin mantenimiento, retirado de Ubuntu reciente | imágenes heredadas de Ubuntu |
| **Florence** | X11 | XTEST | sin mantenimiento | heredado |
| **xvkbd** | X11 | XTEST | más o menos mantenido | inyección de teclas por script, quioscos |
| **Squeekboard** | Wayland | `zwp_input_method_v2` | mantenido | Phosh / móvil |
| **wvkbd** | Wayland | `virtual-keyboard-v1` | mantenido | quioscos wlroots |

> **Nota de examen:** GOK está en los objetivos v5.0 y no es instalable en ninguna distribución actual. Sabé lo que *era*: un teclado en pantalla que soportaba entrada por **escaneo** (un único conmutador recorre cíclicamente grupos de teclas) manejado a través de AT-SPI.

### 3.5 Magnificadores de pantalla

| Herramienta | Servidor | Modos | Efectos de color | Notas |
|---|---|---|---|---|
| **Magnificador de GNOME** (mutter) | X11 + Wayland | pantalla completa/media, lupa | invertir, brillo, contraste, saturación, retículas | `org.gnome.desktop.a11y.magnifier` |
| **Efecto zoom de KWin** | X11 + Wayland | pantalla completa, sigue foco/puntero | inversión mediante efecto aparte | `kwinrc [Plugins] zoomEnabled=true`, `Meta`+`+` |
| **KMagnifier (kmag)** | X11 (ventana) | lupa basada en ventana | limitados | estilo captura de pantalla, no una superposición en vivo bajo Wayland |
| **xzoom / xmag** | solo X11 | basados en ventana | xzoom: espejo/rotación | diminutos, programables, no necesitan compositor |

### 3.6 Mecanismos de entrega de configuración — elegí según la clave

| Mecanismo | Se aplica a | Persistente | Imponible | Adecuado para |
|---|---|---|---|---|
| `gsettings`/`dconf` (usuario) | sesión GNOME | sí | no | la elección propia del usuario |
| **system-db** de `dconf` + `dconf update` | todos los usuarios, valores por defecto | sí | opcional (bloqueos) | **valores por defecto de flota** |
| **bloqueos** de `dconf` | todos los usuarios | sí | **duro** | solo mandatos verdaderos |
| `xkbset` / `setxkbmap -option` | servidor X actual | **no** | no | scripts, hooks por sesión |
| `/etc/X11/xorg.conf.d/*.conf` | arranque del servidor X | sí | sí | valores por defecto de XKB, `XkbOptions` |
| `/etc/vconsole.conf`, `setfont` | renderizado de la VT | sí | sí | fuentes de consola grandes |
| línea de comandos del kernel / `modprobe.d` | arranque | sí | sí | `speakup`, fuente de `fbcon` |
| unidad systemd / udev | demonios, dispositivos | sí | sí | `brltty`, `espeakup` |

---

## 4. Infraestructura: manifiestos completos, sin abreviar

### 4.1 Base de datos de sistema de dconf — valores por defecto de flota

`/etc/dconf/profile/user`

```
user-db:user
system-db:local
```

`/etc/dconf/db/local.d/10-a11y-baseline`

```ini
# Fleet accessibility baseline.
# Managed by Ansible role `a11y_baseline` — edit the role, not this file.
# Rebuild after any change:  dconf update

[org/gnome/desktop/a11y]
# Always keep the Universal Access indicator visible in the top bar, even when
# no feature is active. Users cannot find what is not discoverable.
always-show-universal-access-status=true

[org/gnome/desktop/a11y/applications]
# Defaults only. Users MUST be able to change these; do not lock them.
screen-reader-enabled=false
screen-magnifier-enabled=false
screen-keyboard-enabled=false

[org/gnome/desktop/a11y/interface]
high-contrast=false
show-status-shapes=true

[org/gnome/desktop/a11y/keyboard]
# Master gate for the AccessX keyboard gestures (5x Shift -> Sticky Keys,
# hold Shift 8s -> Slow Keys). Locked ON below: a user who needs Sticky Keys
# may be unable to press the key combination that would enable it.
enable=true
# Do NOT auto-disable accessibility features after idle time.
timeout-enable=false
disable-timeout=120
feature-state-change-beep=true
stickykeys-enable=false
stickykeys-two-key-off=true
stickykeys-modifier-beep=true
slowkeys-enable=false
slowkeys-delay=300
slowkeys-beep-press=false
slowkeys-beep-accept=true
slowkeys-beep-reject=false
bouncekeys-enable=false
bouncekeys-delay=300
bouncekeys-beep-reject=true
mousekeys-enable=false
mousekeys-init-delay=160
mousekeys-max-speed=750
mousekeys-accel-time=1200
togglekeys-enable=false

[org/gnome/desktop/a11y/mouse]
dwell-click-enabled=false
dwell-mode='window'
dwell-threshold=10
dwell-time=1.2
secondary-click-enabled=false
secondary-click-time=1.2

[org/gnome/desktop/a11y/magnifier]
mag-factor=2.0
screen-position='full-screen'
lens-mode=false
scroll-at-edges=true
mouse-tracking='proportional'
focus-tracking='proportional'
caret-tracking='proportional'
invert-lightness=false
show-cross-hairs=true
cross-hairs-thickness=8
cross-hairs-length=4096
cross-hairs-opacity=0.5
cross-hairs-clip=false

[org/gnome/desktop/interface]
cursor-size=32
text-scaling-factor=1.0
cursor-blink=true
cursor-blink-time=1200
# Required for GTK3 applications to publish their object tree on AT-SPI.
toolkit-accessibility=true

[org/gnome/desktop/wm/preferences]
# Visual bell for users who cannot hear the audible one.
audible-bell=false
visual-bell=true
visual-bell-type='frame-flash'

[org/gnome/settings-daemon/plugins/media-keys]
screenreader=['<Alt><Super>s']
magnifier=['<Alt><Super>8']
magnifier-zoom-in=['<Alt><Super>equal']
magnifier-zoom-out=['<Alt><Super>minus']
on-screen-keyboard=['<Alt><Super>k']
```

`/etc/dconf/db/local.d/locks/10-a11y-locks`

```
# Lock ONLY the gates that must never be closed by accident or by a
# misapplied "hardening" profile. Every key that expresses a user's own
# need (screen reader on/off, magnification factor, sticky keys) stays
# writable. Locking those is a fleet-wide accessibility outage.
/org/gnome/desktop/a11y/keyboard/enable
/org/gnome/desktop/a11y/keyboard/timeout-enable
/org/gnome/desktop/a11y/always-show-universal-access-status
/org/gnome/desktop/interface/toolkit-accessibility
```

### 4.2 Greeter de GDM — accesibilidad antes del login

`/etc/dconf/profile/gdm`

```
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
```

`/etc/dconf/db/gdm.d/10-a11y-greeter`

```ini
# The login screen is a separate dconf database with its own profile.
# A user who cannot read the greeter never reaches their own settings.

[org/gnome/desktop/a11y]
always-show-universal-access-status=true

[org/gnome/desktop/a11y/applications]
screen-reader-enabled=false
screen-keyboard-enabled=true
screen-magnifier-enabled=false

[org/gnome/desktop/a11y/keyboard]
enable=true
timeout-enable=false

[org/gnome/desktop/a11y/interface]
high-contrast=true

[org/gnome/desktop/interface]
cursor-size=48
text-scaling-factor=1.25

[org/gnome/login-screen]
banner-message-enable=true
banner-message-text='Accessibility: Alt+Super+S screen reader · Alt+Super+8 magnifier'
```

### 4.3 Entorno: puentes de toolkit para cada familia de aplicaciones

`/etc/environment.d/90-accessibility.conf`

```ini
# Applied by systemd's user environment generator to every user session.
# GTK2 legacy applications:
GTK_MODULES=gail:atk-bridge
# Qt5/Qt6 accessibility bridge (qspiaccessiblebridge plugin):
QT_ACCESSIBILITY=1
QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
# Never set NO_AT_BRIDGE here. If a container base image sets it, unset it
# explicitly in the container entrypoint — it silently mutes the entire
# GTK accessible tree with no log line.
```

`/etc/java/accessibility.properties` (la ruta depende de la distro/JDK, p. ej. `$JAVA_HOME/conf/accessibility.properties`)

```properties
assistive_technologies=org.GNOME.Accessibility.AtkWrapper
screen_magnifier_present=true
```

### 4.4 Línea braille: udev + systemd

`/etc/udev/rules.d/70-braille-display.rules`

```
# Start BRLTTY when the fleet-standard braille display is attached.
# The shipped brltty package also installs autodetection rules under
# /usr/lib/udev/rules.d/ ; this file is the explicit, auditable override.
#
# Discover the IDs first:  udevadm info -a -n /dev/bus/usb/001/00X | head -40
#
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
  ATTR{idVendor}=="0921", ATTR{idProduct}=="1200", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="brltty-console.service", \
  ENV{BRLTTY_BRAILLE_DRIVER}="ht"

ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
  ATTR{idVendor}=="0921", ATTR{idProduct}=="1200", \
  RUN+="/usr/bin/systemctl --no-block stop brltty-console.service"
```

`/etc/systemd/system/brltty-console.service`

```ini
[Unit]
Description=BRLTTY braille daemon (Linux console screen driver)
Documentation=https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
After=local-fs.target systemd-udevd.service
BindsTo=dev-bus-usb.device
StopWhenUnneeded=no

[Service]
Type=simple
# -n  do not fork (systemd owns the lifecycle)
# -e  log to stderr so journald captures everything
# -b  braille driver ("auto" autodetects; explicit is faster and deterministic)
# -d  device specifier: usb: | serial:/dev/ttyS0 | bluetooth:XX:XX:XX:XX:XX:XX
# -x  screen driver: lx = Linux VT via /dev/vcsa* ; a2 = AT-SPI2 (desktop)
# -t  text table   -c  contraction table (grade 2)
ExecStart=/usr/bin/brltty \
  --no-daemon \
  --standard-error \
  --log-level=notice \
  --braille-driver=ht \
  --braille-device=usb: \
  --screen-driver=lx \
  --text-table=en_US \
  --contraction-table=en-ueb-g2 \
  --api-parameters=Auth=/etc/brlapi.key
Restart=on-failure
RestartSec=3
# brltty needs /dev/vcsa* (console text buffer) and raw USB access.
DeviceAllow=char-vcs rw
DeviceAllow=char-usb_device rw
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/run /var/lib/brltty
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/espeakup.service.d/override.conf`

```ini
[Unit]
# espeakup bridges the kernel's /dev/softsynth (speakup_soft) to espeak-ng.
# Without speakup_soft loaded there is nothing to bridge.
After=systemd-modules-load.service
ConditionPathExists=/dev/softsynth

[Service]
ExecStart=
ExecStart=/usr/bin/espeakup --default-voice=en-us
Restart=on-failure
RestartSec=2
```

`/etc/modules-load.d/speakup.conf`

```
# Kernel console screen reader. In mainline since 5.10 (drivers/accessibility).
speakup
speakup_soft
```

`/etc/modprobe.d/speakup.conf`

```
# start=1 makes speakup begin reading immediately when the module loads.
options speakup_soft start=1
```

`/etc/sysctl.d/` no es el lugar adecuado para ajustar speakup — usá una regla de `tmpfiles` para que las perillas de sysfs se apliquen en cada arranque:

`/etc/tmpfiles.d/speakup.conf`

```
#Type Path                                    Mode User Group Age Argument
w     /sys/accessibility/speakup/rate         -    -    -     -   6
w     /sys/accessibility/speakup/punc_level   -    -    -     -   2
w     /sys/accessibility/speakup/key_echo     -    -    -     -   1
```

### 4.5 Renderizado de consola y señales en el arranque

`/etc/vconsole.conf`

```
KEYMAP=us
FONT=ter-132n
FONT_MAP=8859-1
```

`/etc/default/grub` (fragmento relevante)

```bash
# Audible cue that GRUB has started — for users who cannot see the menu.
GRUB_INIT_TUNE="480 440 1"
# Keep the menu visible long enough to be navigated with assistive tech.
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
# Large console font from the very first kernel message.
GRUB_CMDLINE_LINUX_DEFAULT="fbcon=font:TER16x32"
# Serial console in parallel: the only path a remote braille terminal can read.
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
```

### 4.6 Rol de Ansible — todo el conjunto

`roles/a11y_baseline/tasks/main.yml`

```yaml
---
- name: Fail early on unsupported OS families
  ansible.builtin.assert:
    that: ansible_os_family in ['RedHat', 'Debian']
    fail_msg: "a11y_baseline supports RedHat and Debian families only"

- name: Install console accessibility stack
  ansible.builtin.package:
    name: "{{ a11y_console_packages[ansible_os_family] }}"
    state: present
  vars:
    a11y_console_packages:
      RedHat: [brltty, espeakup, espeak-ng, kbd, terminus-fonts-console]
      Debian: [brltty, espeakup, espeak-ng, kbd, console-setup, fonts-terminus-otb]

- name: Install graphical accessibility stack
  ansible.builtin.package:
    name: "{{ a11y_gui_packages[ansible_os_family] }}"
    state: present
  when: a11y_graphical | bool
  vars:
    a11y_gui_packages:
      RedHat:
        - orca
        - speech-dispatcher
        - speech-dispatcher-espeak-ng
        - at-spi2-core
        - at-spi2-atk
        - gnome-themes-extra
        - liblouis
      Debian:
        - orca
        - speech-dispatcher
        - speech-dispatcher-espeak-ng
        - at-spi2-core
        - libatk-adaptor
        - gnome-themes-extra
        - liblouis-data

- name: Deploy dconf profiles
  ansible.builtin.copy:
    src: "profiles/{{ item }}"
    dest: "/etc/dconf/profile/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - user
    - gdm
  notify: dconf update

- name: Ensure dconf database directories exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - /etc/dconf/db/local.d
    - /etc/dconf/db/local.d/locks
    - /etc/dconf/db/gdm.d

- name: Deploy dconf keyfiles and locks
  ansible.builtin.copy:
    src: "db/{{ item }}"
    dest: "/etc/dconf/db/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - local.d/10-a11y-baseline
    - local.d/locks/10-a11y-locks
    - gdm.d/10-a11y-greeter
  notify: dconf update

- name: Deploy session environment for toolkit bridges
  ansible.builtin.copy:
    src: environment.d/90-accessibility.conf
    dest: /etc/environment.d/90-accessibility.conf
    owner: root
    group: root
    mode: "0644"

- name: Assert NO_AT_BRIDGE is not exported anywhere in /etc
  ansible.builtin.command:
    argv: [grep, -RIl, --exclude-dir=dconf, NO_AT_BRIDGE, /etc]
  register: no_at_bridge
  changed_when: false
  failed_when: false

- name: Fail if NO_AT_BRIDGE poisons the environment
  ansible.builtin.fail:
    msg: "NO_AT_BRIDGE found in: {{ no_at_bridge.stdout_lines | join(', ') }}"
  when: no_at_bridge.stdout | length > 0

- name: Configure kernel console screen reader
  ansible.builtin.copy:
    content: "{{ item.content }}"
    dest: "{{ item.dest }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - dest: /etc/modules-load.d/speakup.conf
      content: "speakup\nspeakup_soft\n"
    - dest: /etc/modprobe.d/speakup.conf
      content: "options speakup_soft start=1\n"
  notify: reload speakup

- name: Configure large console font
  ansible.builtin.copy:
    content: |
      KEYMAP={{ a11y_console_keymap }}
      FONT={{ a11y_console_font }}
      FONT_MAP=8859-1
    dest: /etc/vconsole.conf
    owner: root
    group: root
    mode: "0644"
  notify: apply vconsole

- name: Deploy braille udev rule
  ansible.builtin.template:
    src: 70-braille-display.rules.j2
    dest: /etc/udev/rules.d/70-braille-display.rules
    owner: root
    group: root
    mode: "0644"
  when: a11y_braille_enabled | bool
  notify: reload udev

- name: Deploy brltty console unit
  ansible.builtin.template:
    src: brltty-console.service.j2
    dest: /etc/systemd/system/brltty-console.service
    owner: root
    group: root
    mode: "0644"
  when: a11y_braille_enabled | bool
  notify: daemon reload

- name: Generate a BrlAPI authorisation key if absent
  ansible.builtin.shell:
    cmd: "set -o pipefail && head -c 32 /dev/urandom > /etc/brlapi.key"
    creates: /etc/brlapi.key
  when: a11y_braille_enabled | bool

- name: Restrict the BrlAPI key
  ansible.builtin.file:
    path: /etc/brlapi.key
    owner: root
    group: brlapi
    mode: "0640"
  when: a11y_braille_enabled | bool

- name: Enable espeakup where speech is required
  ansible.builtin.systemd_service:
    name: espeakup.service
    enabled: true
    state: started
  when: a11y_console_speech | bool

- name: Deploy the verification script
  ansible.builtin.copy:
    src: bin/a11y-verify.sh
    dest: /usr/local/bin/a11y-verify
    owner: root
    group: root
    mode: "0755"

- name: Run the verification script (fails the play on drift)
  ansible.builtin.command: /usr/local/bin/a11y-verify --strict
  register: a11y_verify
  changed_when: false
```

`roles/a11y_baseline/defaults/main.yml`

```yaml
---
a11y_graphical: true
a11y_braille_enabled: false
a11y_console_speech: false
a11y_console_font: ter-132n
a11y_console_keymap: us
a11y_braille_driver: ht
a11y_braille_vendor_id: "0921"
a11y_braille_product_id: "1200"
a11y_text_table: en_US
a11y_contraction_table: en-ueb-g2
```

`roles/a11y_baseline/handlers/main.yml`

```yaml
---
- name: dconf update
  ansible.builtin.command: /usr/bin/dconf update

- name: daemon reload
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: reload udev
  ansible.builtin.command: /usr/bin/udevadm control --reload-rules

- name: reload speakup
  ansible.builtin.command: /usr/sbin/modprobe -r speakup_soft speakup
  failed_when: false
  notify: load speakup

- name: load speakup
  ansible.builtin.command: /usr/sbin/modprobe speakup_soft

- name: apply vconsole
  ansible.builtin.systemd_service:
    name: systemd-vconsole-setup.service
    state: restarted
```

### 4.7 Auditoría de deriva de flota como CronJob de Kubernetes

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: a11y-audit-script
  namespace: platform-compliance
data:
  audit.sh: |
    #!/usr/bin/env bash
    # Fleet accessibility drift audit.
    # Exit 0 = compliant, 1 = drift, 2 = unreachable.
    set -euo pipefail
    HOST="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "audit@${HOST}" 'bash -s' <<'REMOTE' || exit 2
    set -uo pipefail
    rc=0
    emit() { printf '%-38s %s\n' "$1" "$2"; }

    # 1. dconf system database is compiled and newer than its sources.
    if [ ! -f /etc/dconf/db/local ]; then
      emit "dconf.local.compiled" "FAIL(missing)"; rc=1
    elif [ -n "$(find /etc/dconf/db/local.d -newer /etc/dconf/db/local 2>/dev/null)" ]; then
      emit "dconf.local.compiled" "FAIL(stale: run dconf update)"; rc=1
    else
      emit "dconf.local.compiled" "OK"
    fi

    # 2. The AccessX gate must be on and locked.
    gate=$(dconf read -d /org/gnome/desktop/a11y/keyboard/enable 2>/dev/null || echo unset)
    [ "$gate" = "true" ] && emit "a11y.keyboard.enable" "OK" \
      || { emit "a11y.keyboard.enable" "FAIL($gate)"; rc=1; }

    # 3. Idle auto-disable of a11y features must be off.
    to=$(dconf read -d /org/gnome/desktop/a11y/keyboard/timeout-enable 2>/dev/null || echo unset)
    [ "$to" = "false" ] && emit "a11y.keyboard.timeout-enable" "OK" \
      || { emit "a11y.keyboard.timeout-enable" "FAIL($to)"; rc=1; }

    # 4. No NO_AT_BRIDGE anywhere in the system environment.
    if grep -RIqs NO_AT_BRIDGE /etc/environment /etc/environment.d /etc/profile.d 2>/dev/null; then
      emit "env.NO_AT_BRIDGE" "FAIL(present)"; rc=1
    else
      emit "env.NO_AT_BRIDGE" "OK"
    fi

    # 5. Console screen-reader path present.
    if [ -c /dev/softsynth ]; then emit "speakup.softsynth" "OK"
    else emit "speakup.softsynth" "WARN(absent)"; fi

    # 6. Large console font actually applied.
    font=$(grep -E '^FONT=' /etc/vconsole.conf 2>/dev/null | cut -d= -f2)
    [ -n "${font:-}" ] && emit "vconsole.font" "OK($font)" \
      || { emit "vconsole.font" "FAIL(unset)"; rc=1; }

    exit "$rc"
    REMOTE
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: a11y-drift-audit
  namespace: platform-compliance
  labels:
    app.kubernetes.io/name: a11y-drift-audit
    app.kubernetes.io/component: compliance
spec:
  schedule: "17 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 7
  startingDeadlineSeconds: 600
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: audit
              image: registry.internal/platform/ssh-auditor:1.7.2
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -uo pipefail
                  fail=0
                  while read -r host; do
                    echo "=== ${host} ==="
                    if /scripts/audit.sh "${host}"; then
                      echo "result=compliant host=${host}"
                    else
                      echo "result=drift host=${host} rc=$?"
                      fail=1
                    fi
                  done < /inventory/workstations.txt
                  exit "${fail}"
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
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: inventory
                  mountPath: /inventory
                  readOnly: true
                - name: ssh-key
                  mountPath: /home/audit/.ssh
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: a11y-audit-script
                defaultMode: 0555
            - name: inventory
              configMap:
                name: fleet-inventory
            - name: ssh-key
              secret:
                secretName: a11y-audit-ssh-key
                defaultMode: 0400
            - name: tmp
              emptyDir:
                sizeLimit: 16Mi
```

---

## 5. CLI: comandos reales y salida esperada

### 5.1 Accesibilidad de teclado en X11 — controles AccessX de XKB

```
$ xkbset q
Bell:                    on
Sticky Keys:             off
        Two Keys:        off
        Latch Lock:      off
Mouse Keys:              off
        Delay:           160
        Interval:        40
        Time to Max:     30
        Max Speed:       30
        Curve:           0
Access X Keys:           on
Access X Timeout:        0
        Timeout Mask:    -none-
        Timeout Values:  -none-
        Options Mask:    -none-
        Options Values:  -none-
Access X Feedback:       off
        Feedback Mask:   -none-
Slow Keys:               off
        Delay:           300
Bounce Keys:             off
        Delay:           300
Repeat Keys:             on
        Delay:           660
        Rate:            25
```

Activar Sticky Keys (los modificadores quedan enganchados en vez de exigir pulsaciones simultáneas), deshabilitando la vía de escape de "dos teclas pulsadas juntas lo desactivan":

```
$ xkbset sticky -twokey -latchlock
$ xkbset q | head -4
Bell:                    on
Sticky Keys:             on
        Two Keys:        off
        Latch Lock:      on
```

**La trampa que cuesta una hora:** las funciones AccessX expiran con el timeout de AccessX. Si se apagan solas al cabo de un par de minutos, decile al servidor X que no las deje expirar:

```
$ xkbset m            # Mouse Keys on
$ xkbset exp =m       # ...and do not let it expire
$ xkbset exp "=sticky" "=twokey" "=latchlock" "=bell"
```

Mouse Keys — mover el puntero con el teclado numérico:

```
$ xkbset m 160 40 30 30 0
#          │   │  │  │  └─ curve (0 = linear acceleration)
#          │   │  │  └──── max speed (px per interval)
#          │   │  └─────── time to reach max speed (intervals)
#          │   └────────── interval between pointer moves (ms)
#          └────────────── initial delay before repeating (ms)
```

Slow Keys (ignorar teclas mantenidas menos de N ms — filtra roces provocados por temblor) y Bounce Keys (ignorar la repetición de la misma tecla dentro de N ms):

```
$ xkbset sl 400        # Slow Keys, 400 ms acceptance delay
$ xkbset bo 500        # Bounce Keys, 500 ms debounce
$ xkbset q | grep -A1 -E 'Slow|Bounce'
Slow Keys:               on
        Delay:           400
Bounce Keys:             on
        Delay:           500
```

Repeat Keys mediante el clásico `xset` (retardo antes de repetir, repeticiones por segundo):

```
$ xset r rate 660 25
$ xset q | grep -A2 'auto repeat delay'
  auto repeat delay:  660    repeat rate:  25
  auto repeating keys:  00feffffdffffbbf
                        fadfffefffedffff
```

Persistir las opciones de XKB de forma declarativa en vez de programar `xkbset` en el login:

`/etc/X11/xorg.conf.d/50-accessx.conf`

```
Section "InputClass"
    Identifier   "AccessX keyboard defaults"
    MatchIsKeyboard "on"
    Option       "XkbLayout"  "us"
    Option       "XkbOptions" "grp:alt_shift_toggle,terminate:ctrl_alt_bksp"
EndSection
```

> **Crítico:** cualquier recarga con `setxkbmap` o `xkbcomp` **reemplaza todo el mapa de teclado y resetea el estado de AccessX**. Un applet de escritorio, un evento de hotplug o un cambio de método de entrada pueden, por lo tanto, deshacer silenciosamente `xkbset`. Esta es la causa raíz más común de "Sticky Keys se desactivó solo" — y la razón arquitectónica para configurar vía `org.gnome.desktop.a11y.keyboard` (reaplicado por gnome-settings-daemon tras cada cambio de mapa de teclado) en vez de `xkbset` en un sistema GNOME.

### 5.2 La superficie de GNOME/GSettings

```
$ gsettings list-recursively org.gnome.desktop.a11y.keyboard
org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject true
org.gnome.desktop.a11y.keyboard bouncekeys-delay 300
org.gnome.desktop.a11y.keyboard bouncekeys-enable false
org.gnome.desktop.a11y.keyboard disable-timeout 120
org.gnome.desktop.a11y.keyboard enable true
org.gnome.desktop.a11y.keyboard feature-state-change-beep true
org.gnome.desktop.a11y.keyboard mousekeys-accel-time 1200
org.gnome.desktop.a11y.keyboard mousekeys-enable false
org.gnome.desktop.a11y.keyboard mousekeys-init-delay 160
org.gnome.desktop.a11y.keyboard mousekeys-max-speed 750
org.gnome.desktop.a11y.keyboard slowkeys-beep-accept true
org.gnome.desktop.a11y.keyboard slowkeys-beep-press false
org.gnome.desktop.a11y.keyboard slowkeys-beep-reject false
org.gnome.desktop.a11y.keyboard slowkeys-delay 300
org.gnome.desktop.a11y.keyboard slowkeys-enable false
org.gnome.desktop.a11y.keyboard stickykeys-enable false
org.gnome.desktop.a11y.keyboard stickykeys-modifier-beep true
org.gnome.desktop.a11y.keyboard stickykeys-two-key-off true
org.gnome.desktop.a11y.keyboard timeout-enable false
org.gnome.desktop.a11y.keyboard togglekeys-enable false
```

Alternar las tres funciones de "applications" — que son las que maneja el panel de Acceso Universal:

```
$ gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
$ gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
$ gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
$ gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled
true
```

Alto contraste y letra grande — la mitad de "temas" del objetivo:

```
$ gsettings set org.gnome.desktop.a11y.interface high-contrast true
$ gsettings set org.gnome.desktop.interface text-scaling-factor 1.5
$ gsettings set org.gnome.desktop.interface cursor-size 48
$ gsettings get org.gnome.desktop.interface text-scaling-factor
1.5
```

En GNOME anterior a 42 el mismo efecto era un cambio de tema GTK; conocé ambas formas:

```
$ gsettings set org.gnome.desktop.interface gtk-theme 'HighContrast'
$ gsettings set org.gnome.desktop.interface icon-theme 'HighContrast'
```

Magnificador:

```
$ gsettings set org.gnome.desktop.a11y.magnifier mag-factor 3.0
$ gsettings set org.gnome.desktop.a11y.magnifier lens-mode true
$ gsettings set org.gnome.desktop.a11y.magnifier mouse-tracking 'proportional'
$ gsettings set org.gnome.desktop.a11y.magnifier invert-lightness true
$ gsettings set org.gnome.desktop.a11y.magnifier show-cross-hairs true
```

Clic por permanencia (hacer clic sin pulsar un botón — para usuarios que pueden mover un puntero pero no hacer clic):

```
$ gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
$ gsettings set org.gnome.desktop.a11y.mouse dwell-time 1.2
$ gsettings set org.gnome.desktop.a11y.mouse dwell-threshold 10
$ gsettings set org.gnome.desktop.a11y.mouse secondary-click-enabled true
```

Verificar que un bloqueo de system-db está realmente en vigor:

```
$ dconf update
$ gsettings writable org.gnome.desktop.a11y.keyboard enable
false
$ gsettings set org.gnome.desktop.a11y.keyboard enable false
(process:48211): dconf-WARNING **: 11:04:22.517: failed to commit changes to dconf: 
The operation is not permitted because the key is locked
```

### 5.3 Bus AT-SPI2 — ¿está viva la fontanería de accesibilidad?

```
$ busctl --user list | grep -i a11y
org.a11y.Bus                       4821 at-spi-bus-laun dalmine :1.34  ...
org.a11y.atspi.Registry            4839 at-spi2-registr dalmine :1.41  ...

$ dbus-send --session --print-reply --dest=org.a11y.Bus \
    /org/a11y/bus org.a11y.Bus.GetAddress
method return time=1787050122.884413 sender=:1.34 -> destination=:1.212 serial=9 reply_serial=2
   string "unix:path=/run/user/1000/at-spi/bus_0,guid=6f0c9b2a1d4e7f8a3b5c6d70"

$ gsettings get org.gnome.desktop.interface toolkit-accessibility
true

$ ps -ef | grep -E 'at-spi|orca' | grep -v grep
dalmine    4821  4712  0 10:58 ?  00:00:00 /usr/libexec/at-spi-bus-launcher --launch-immediately
dalmine    4839  4821  0 10:58 ?  00:00:01 /usr/libexec/at-spi2-registryd --use-gnome-session
dalmine    5104  4712  1 11:01 ?  00:00:07 /usr/bin/python3 /usr/bin/orca
```

Confirmar que una aplicación individual publica un árbol de objetos (Accerciser es la GUI; comprobación programable sin `xdotool` mediante `python3-pyatspi`):

```
$ python3 -c 'import pyatspi; print([a.name for a in pyatspi.Registry.getDesktop(0)])'
['gnome-shell', 'gnome-terminal-server', 'firefox', 'nautilus']
```

Una aplicación ausente de esa lista es invisible para todos los lectores de pantalla de la máquina — esa es la verdadera definición de "no accesible".

### 5.4 Orca

```
$ orca --version
Orca 45.2

$ orca --replace &
[1] 5104

$ orca --help
Usage: orca [OPTION...]

  -h, --help                       Show this help message and exit
  -v, --version                    Version of Orca
  -s, --setup                      Set up user preferences (GUI version)
  -u, --user-prefs=DIRNAME         Use alternate directory for user preferences
  -e, --enable=SPEECH|BRAILLE|BRAILLE-MONITOR
  -d, --disable=SPEECH|BRAILLE|BRAILLE-MONITOR
  -p, --profile=NAME               Load profile
  -r, --replace                    Replace a currently running instance
  --debug                          Send debug output to debug-YYYY-MM-DD-HH:MM:SS.out
  --debug-file=FILE                Send debug output to the specified file
```

Combinaciones de teclas por defecto (**disposición de escritorio**; el modificador de Orca es `Insert`/`KP_Insert`, o `CapsLock` en la disposición de portátil):

| Combinación | Acción |
|---|---|
| `Orca` + `Space` | Diálogo de preferencias |
| `Orca` + `H` | Modo aprendizaje (anuncia cada tecla sin ejecutarla) |
| `Orca` + `S` | Alternar el habla |
| `Orca` + `Q` | Salir de Orca |
| `KP_Add` | Leer todo (leer desde el cursor hasta el final) |
| `KP_5` | Revisión plana: leer la línea actual |
| `Alt`+`Super`+`S` | Atajo de GNOME para activar/desactivar el lector de pantalla |

Capturar una traza de depuración para un informe de error — esto es lo que pide upstream:

```
$ orca --replace --debug-file=/tmp/orca-$(date +%F).out
$ tail -5 /tmp/orca-2026-08-27.out
DEBUG: script_manager.getScript: Firefox (pid 4977)
DEBUG: focus changed to: [document frame | LPI Objectives]
DEBUG: speech.speak: 'LPI Objectives, document frame'
DEBUG: braille.displayMessage: 'LPI Objectives doc frm'
```

### 5.5 Habla: speech-dispatcher y espeak-ng

```
$ spd-say -t male1 "Accessibility check on host $(hostname -s)"

$ spd-say -L
NAME                    LANGUAGE  VARIANT
Afrikaans               af        none
English (America)       en-US     none
English (Great Britain) en-GB     none
Spanish                 es        none
Spanish (Latin America) es-419    none
...

$ spd-say -O
OUTPUT MODULE
espeak-ng
festival
pico
dummy

$ spd-say -r 60 -p 20 "faster and higher pitched"

$ espeak-ng --version
eSpeak NG text-to-speech: 1.51  Data at: /usr/share/espeak-ng-data

$ espeak-ng -v en-us -s 300 "direct synthesis, bypassing speech dispatcher"

$ systemctl --user status speech-dispatcherd.service
● speech-dispatcherd.service - Speech-Dispatcher: Common interface to speech synthesis
     Loaded: loaded (/usr/lib/systemd/user/speech-dispatcherd.service; static)
     Active: active (running) since Thu 2026-08-27 11:02:41 -03; 12min ago
   Main PID: 5233 (speech-dispatch)
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/speech-dispatcherd.service
             ├─5233 /usr/bin/speech-dispatcher --spawn --communication-method unix_socket
             └─5241 sd_espeak-ng /etc/speech-dispatcher/modules/espeak-ng.conf
```

Archivos de configuración clave:

| Ruta | Propósito |
|---|---|
| `/etc/speech-dispatcher/speechd.conf` | valores por defecto del sistema: `DefaultModule`, `AudioOutputMethod`, `DefaultRate` |
| `/etc/speech-dispatcher/modules/*.conf` | configuración por módulo de sintetizador |
| `~/.config/speech-dispatcher/speechd.conf` | anulación por usuario (creada por `spd-conf`) |
| `~/.cache/speech-dispatcher/log/speech-dispatcher.log` | el log que hay que leer cuando se queda mudo |

### 5.6 Lectura de pantalla en consola: speakup + espeakup

```
$ sudo modprobe speakup_soft
$ lsmod | grep speakup
speakup_soft           16384  0
speakup               159744  1 speakup_soft

$ ls /sys/accessibility/speakup/
attrib_bleep  bleep_time  cursor_time  ex_num     keymap        punc_all
punc_some     say_control  silent      spell_delay  synth_direct
bell_pos      bleeps      delimiters   key_echo   no_interrupt  punc_level
reading_punc  repeats      say_word_ctl  soft      synth        version

$ cat /sys/accessibility/speakup/synth
soft
$ cat /sys/accessibility/speakup/version
Speakup v-3.1.6-dev
$ echo 6 | sudo tee /sys/accessibility/speakup/rate
6
$ echo 2 | sudo tee /sys/accessibility/speakup/punc_level
2

$ ls -l /dev/softsynth
crw-rw---- 1 root root 10, 26 Aug 27 11:14 /dev/softsynth

$ sudo systemctl enable --now espeakup.service
$ systemctl is-active espeakup.service
active
```

El control de lectura en la VT usa el **teclado numérico** como teclas de revisión (`KP_8`/`KP_2` línea arriba/abajo, `KP_5` línea actual, `KP_Enter` leer todo, `KP_Ins`+`Q` silenciar). Speakup es por VT: cambiar con `Chvt`/`Ctrl`+`Alt`+`F3` da un cursor de revisión independiente.

Activación en el arranque cuando speakup está compilado dentro del kernel:

```
$ sudo grubby --update-kernel=ALL --args="speakup.synth=soft"
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.11.9-200.fc41.x86_64 root=UUID=... rw \
  fbcon=font:TER16x32 speakup.synth=soft
```

### 5.7 Braille: BRLTTY y BrlAPI

```
$ brltty --version
BRLTTY 6.6 (Jan  1 2024)
Copyright (C) 1995-2024 by The BRLTTY Developers.
BRLTTY comes with ABSOLUTELY NO WARRANTY.

$ lsusb | grep -i -E 'braille|handy|baum|freedom'
Bus 001 Device 007: ID 0921:1200 Handy Tech Elektronik GmbH Braille Display

$ sudo brltty -n -e -l debug -b auto -d usb: -x lx -t en_US
brltty: BRLTTY 6.6 rev ...
brltty: Working Directory: /
brltty: Configuration File: /etc/brltty.conf
brltty: Tables Directory: /etc/brltty
brltty: Braille Driver: ht [HandyTech]
brltty: Braille Device: usb:
brltty: Detected HandyTech Active Braille 40 (serial 12345)
brltty: Text Table: en_US
brltty: Screen Driver: lx [Linux]
brltty: STARTED

$ systemctl status brltty-console.service
● brltty-console.service - BRLTTY braille daemon (Linux console screen driver)
     Loaded: loaded (/etc/systemd/system/brltty-console.service; enabled)
     Active: active (running) since Thu 2026-08-27 11:22:07 -03; 3min 41s ago
       Docs: https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
   Main PID: 6104 (brltty)
      Tasks: 4 (limit: 18956)
     CGroup: /system.slice/brltty-console.service
             └─6104 /usr/bin/brltty --no-daemon --standard-error ...

$ ss -lntp | grep 4101
LISTEN 0  8  127.0.0.1:4101  0.0.0.0:*  users:(("brltty",pid=6104,fd=9))
```

Opciones clave de BRLTTY para el examen y para el trabajo real:

| Opción | Significado |
|---|---|
| `-b`, `--braille-driver` | código de driver de dos letras (`ht`, `bm`, `al`, `fs`, `hw`, `pm`, `no`, `auto`) |
| `-d`, `--braille-device` | `usb:`, `serial:/dev/ttyS0`, `bluetooth:XX:XX:XX:XX:XX:XX` |
| `-x`, `--screen-driver` | `lx` (VT de Linux vía `/dev/vcsa*`) o `a2` (AT-SPI2, para escritorios) |
| `-t`, `--text-table` | mapeo carácter→puntos, p. ej. `en_US`, `es`, `de` |
| `-c`, `--contraction-table` | contracción de grado 2, p. ej. `en-ueb-g2` |
| `-s`, `--speech-driver` | habla opcional junto al braille (`sd` = speech-dispatcher, `es` = eSpeak) |
| `-n`, `-e`, `-l` | primer plano, registro por stderr, nivel de log — la tríada de depuración |

Orca llega a la misma línea a través de **BrlAPI** (TCP `127.0.0.1:4101`, autenticado por `/etc/brlapi.key`) y hace la contracción por su cuenta con **liblouis**. El braille tiene entonces dos consumidores independientes: BRLTTY para la consola, Orca para el escritorio. No deben manejar la línea los dos a la vez.

### 5.8 Renderizado de consola: letra grande sin GUI

```
$ setfont ter-132n
$ showconsolefont | head -3
Character count: 256
Font width     : 16
Font height    : 32

$ ls /usr/share/kbd/consolefonts/ | grep -E '^ter-1(16|24|32)'
ter-116b.psf.gz  ter-116n.psf.gz  ter-124b.psf.gz  ter-124n.psf.gz
ter-132b.psf.gz  ter-132n.psf.gz

$ sudo sed -i 's/^FONT=.*/FONT=ter-132n/' /etc/vconsole.conf
$ sudo systemctl restart systemd-vconsole-setup.service
$ journalctl -u systemd-vconsole-setup.service -n 3
systemd-vconsole-setup[7231]: /usr/bin/setfont succeeded.
systemd-vconsole-setup[7231]: /usr/bin/loadkeys succeeded.
```

Repetición de teclas en consola (el equivalente en la VT de Repeat Keys):

```
$ sudo kbdrate -d 1000 -r 2.0
Typematic Rate set to 2.0 cps (delay = 1000 ms)
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 El script de verificación

`/usr/local/bin/a11y-verify`

```bash
#!/usr/bin/env bash
# Accessibility posture verification. Idempotent, read-only, no side effects.
#   exit 0 = all checks pass
#   exit 1 = at least one FAIL (with --strict, warnings also fail)
set -uo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1
rc=0
pass() { printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "${2:-}"; }
warn() { printf '  \033[33mWARN\033[0m  %-34s %s\n' "$1" "${2:-}"; \
         [[ $STRICT -eq 1 ]] && rc=1; return 0; }
fail() { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "${2:-}"; rc=1; }

echo "== Console layer =="
[[ -c /dev/vcsa1 ]] && pass "/dev/vcsa1"      "console text buffer readable" \
                    || fail "/dev/vcsa1"      "missing — no console screen reading"
lsmod | grep -q '^speakup' && pass "speakup module" "$(cat /sys/accessibility/speakup/version 2>/dev/null)" \
                           || warn "speakup module" "not loaded"
[[ -c /dev/softsynth ]]   && pass "/dev/softsynth"  "software synth endpoint present" \
                          || warn "/dev/softsynth"  "speakup_soft not loaded"
systemctl is-active --quiet espeakup.service && pass "espeakup.service" "active" \
                                             || warn "espeakup.service" "inactive"
f=$(grep -E '^FONT=' /etc/vconsole.conf 2>/dev/null | cut -d= -f2)
[[ -n $f ]] && pass "vconsole FONT" "$f" || fail "vconsole FONT" "unset"

echo "== Braille layer =="
command -v brltty >/dev/null && pass "brltty binary" "$(brltty --version | head -1)" \
                             || warn "brltty binary" "not installed"
if systemctl is-active --quiet brltty-console.service; then
  pass "brltty-console.service" "active"
  ss -lnt 2>/dev/null | grep -q ':4101' && pass "BrlAPI :4101" "listening" \
                                        || warn "BrlAPI :4101" "not listening"
else
  warn "brltty-console.service" "inactive (no display attached?)"
fi

echo "== Graphical layer =="
if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
  busctl --user list 2>/dev/null | grep -q org.a11y.Bus \
    && pass "org.a11y.Bus" "registered" || fail "org.a11y.Bus" "AT-SPI bus absent"
  pgrep -x at-spi2-registryd >/dev/null \
    && pass "at-spi2-registryd" "running" || fail "at-spi2-registryd" "not running"
  [[ "$(gsettings get org.gnome.desktop.interface toolkit-accessibility 2>/dev/null)" == "true" ]] \
    && pass "toolkit-accessibility" "true" || fail "toolkit-accessibility" "false — GTK3 apps mute"
  [[ -z ${NO_AT_BRIDGE:-} ]] && pass "NO_AT_BRIDGE" "unset" \
                             || fail "NO_AT_BRIDGE" "set to '${NO_AT_BRIDGE}' — bridge disabled"
  [[ "$(gsettings get org.gnome.desktop.a11y.keyboard enable 2>/dev/null)" == "true" ]] \
    && pass "a11y.keyboard.enable" "true" || fail "a11y.keyboard.enable" "AccessX gestures off"
  [[ "$(gsettings get org.gnome.desktop.a11y.keyboard timeout-enable 2>/dev/null)" == "false" ]] \
    && pass "a11y idle auto-disable" "off" || fail "a11y idle auto-disable" "features expire on idle"
  command -v orca >/dev/null && pass "orca" "$(orca --version 2>&1 | head -1)" \
                             || warn "orca" "not installed"
  spd-say -O 2>/dev/null | grep -q . && pass "speech-dispatcher modules" \
      "$(spd-say -O 2>/dev/null | tail -n +2 | tr '\n' ' ')" \
    || fail "speech-dispatcher modules" "none available"
else
  warn "graphical layer" "no DISPLAY/WAYLAND_DISPLAY — headless, skipped"
fi

echo "== dconf policy =="
if [[ -f /etc/dconf/db/local ]]; then
  if [[ -n "$(find /etc/dconf/db/local.d -newer /etc/dconf/db/local 2>/dev/null)" ]]; then
    fail "dconf db/local" "stale — run: dconf update"
  else
    pass "dconf db/local" "compiled and current"
  fi
else
  fail "dconf db/local" "not compiled"
fi

exit "$rc"
```

Ejecución limpia esperada:

```
$ a11y-verify
== Console layer ==
  PASS  /dev/vcsa1                         console text buffer readable
  PASS  speakup module                     Speakup v-3.1.6-dev
  PASS  /dev/softsynth                     software synth endpoint present
  PASS  espeakup.service                   active
  PASS  vconsole FONT                      ter-132n
== Braille layer ==
  PASS  brltty binary                      BRLTTY 6.6 (Jan  1 2024)
  PASS  brltty-console.service             active
  PASS  BrlAPI :4101                       listening
== Graphical layer ==
  PASS  org.a11y.Bus                       registered
  PASS  at-spi2-registryd                  running
  PASS  toolkit-accessibility              true
  PASS  NO_AT_BRIDGE                       unset
  PASS  a11y.keyboard.enable               true
  PASS  a11y idle auto-disable             off
  PASS  orca                               Orca 45.2
  PASS  speech-dispatcher modules          espeak-ng festival pico dummy
== dconf policy ==
  PASS  dconf db/local                     compiled and current
$ echo $?
0
```

### 6.2 Síntoma → causa raíz → comando

| Síntoma | Causa más probable | Comando de confirmación | Solución |
|---|---|---|---|
| Orca arranca y no dice absolutamente nada | speech-dispatcher muerto o sink de audio equivocado | `spd-say test` | revisar `~/.cache/speech-dispatcher/log/`; poner `AudioOutputMethod "pulse"` en `speechd.conf` |
| Orca habla en apps de GNOME, muda en una app | el puente de ese toolkit está apagado | `python3 -c 'import pyatspi; print([a.name for a in pyatspi.Registry.getDesktop(0)])'` | `QT_ACCESSIBILITY=1`; `accessibility.properties` de Java; Chromium `--force-renderer-accessibility` |
| **Todas** las apps GTK3 son invisibles para Orca | `toolkit-accessibility=false` o `NO_AT_BRIDGE=1` | `gsettings get org.gnome.desktop.interface toolkit-accessibility`; `env \| grep NO_AT` | poner el gsetting en true; purgar `NO_AT_BRIDGE` de imágenes/entrypoints |
| Nada accesible dentro de una app Flatpak | falta el permiso del sandbox | `flatpak info --show-permissions <app>` | `flatpak override --socket=accessibility <app>` |
| Sticky Keys se apaga solo tras ~2 min | expiración del timeout de AccessX | `xkbset q \| grep -A2 Timeout` | `xkbset exp "=sticky"`, o `timeout-enable=false` en dconf |
| Sticky Keys se resetea al cambiar la disposición de teclado | `setxkbmap` recarga el mapa y borra AccessX | `xev -event keyboard` tras un cambio de disposición | configurar vía `org.gnome.desktop.a11y.keyboard`, no `xkbset` |
| Los gestos 5×Shift / mantener Shift no hacen nada | compuerta maestra apagada | `gsettings get org.gnome.desktop.a11y.keyboard enable` | poner en `true` (y bloquearla) |
| La línea braille no se detecta | regla de udev / permisos / driver equivocado | `udevadm monitor --udev`; `sudo brltty -n -e -l debug -b auto -d usb:` | corregir `idVendor`/`idProduct`, recargar reglas, elegir el `-b` correcto |
| El braille funciona en la VT, muerto en el escritorio | driver de pantalla equivocado | revisar `--screen-driver` | `-x a2` para AT-SPI2, o dejar que Orca maneje la línea vía BrlAPI |
| Orca no puede abrir la línea braille | BRLTTY ya la tiene tomada, o autenticación de BrlAPI | `ss -lntp \| grep 4101`; `ls -l /etc/brlapi.key` | un solo consumidor; agregar el usuario al grupo `brlapi` |
| `xkbset`/`xdotool` "no tienen efecto" | la sesión es Wayland | `echo $XDG_SESSION_TYPE` | usar gsettings / APIs del compositor; las herramientas de X solo afectan a XWayland |
| Las teclas del magnificador no hacen nada en sway/wlroots | no hay implementación de magnificador en el compositor | `echo $XDG_SESSION_TYPE`, documentación del compositor | usar GNOME/Plasma para usuarios críticos en a11y |
| La pantalla de login no tiene accesibilidad alguna | el greeter usa la base de datos dconf `gdm`, no `local` | `cat /etc/dconf/profile/gdm` | poblar `/etc/dconf/db/gdm.d/` + `dconf update` |
| Los ajustes se aplican a root, no a los usuarios | se olvidó `dconf update`, o perfil equivocado | `ls -l /etc/dconf/db/local*` y comparar mtimes | `dconf update`; verificar que `/etc/dconf/profile/user` lista `system-db:local` |
| El habla en consola funciona, nada en initramfs / rescate | speakup+espeakup no están en el initramfs | `lsinitrd \| grep -E 'speakup\|espeak'` | aceptar la brecha y proveer acceso serie/BMC, o construir un initramfs a medida |
| Lector de pantalla mudo sobre `ssh -X` | AT-SPI es local a la sesión; X11 solo reenvía píxeles | `dbus-send ... org.a11y.Bus.GetAddress` en el host remoto | ejecutar toda la sesión remotamente (VNC/RDP) con reenvío de audio |

### 6.3 Árbol de decisión de diagnóstico — "el lector de pantalla está mudo"

```
Screen reader silent
├─ Graphical session?
│  ├─ NO → console layer
│  │   ├─ /dev/softsynth missing?      → modprobe speakup_soft
│  │   ├─ espeakup inactive?           → systemctl start espeakup
│  │   ├─ silent flag set?             → echo 0 > /sys/accessibility/speakup/silent
│  │   └─ no audio device?             → aplay -l ; check the codec/HDMI sink
│  └─ YES
│     ├─ `spd-say test` audible?
│     │   ├─ NO  → speech-dispatcher / audio problem  (STOP — not an a11y problem)
│     │   └─ YES → the object tree is the problem, continue
│     ├─ org.a11y.Bus registered?      → NO: at-spi2-core missing / bus-launcher crashed
│     ├─ App present in getDesktop(0)? → NO: toolkit bridge off for that app
│     │                                        (NO_AT_BRIDGE / QT_ACCESSIBILITY /
│     │                                         toolkit-accessibility / Flatpak socket)
│     └─ App present but no focus events?
│         └─ compositor not delivering focus  → Wayland on an unsupported compositor
```

### 6.4 Lo que esta escalera **no** demuestra

Cada comprobación de arriba verifica que la *maquinaria* está presente y conectada. Ninguna verifica que la experiencia resultante sea usable: orden de lectura correcto, etiquetas de widget con sentido, ratio de contraste suficiente o una ruta de teclado a cada función. Eso requiere una evaluación WCAG/EN 301 549 con un usuario real de tecnología asistiva. Tratá la verificación automatizada de a11y exactamente como un health check — necesaria, barata, ejecutada continuamente, y nunca un sustituto de la prueba real.

---

## 7. Resumen orientado al examen

**Memorizá la correspondencia entre nombre de función y mecanismo:**

| Función | Qué hace | Mecanismo X11 / consola | Clave de GNOME |
|---|---|---|---|
| **Sticky Keys** | los modificadores quedan enganchados; no hace falta pulsación simultánea | `xkbset sticky` | `stickykeys-enable` |
| **Repeat Keys** | retardo y frecuencia de autorrepetición | `xset r rate D R` / `kbdrate` | `org.gnome.desktop.peripherals.keyboard repeat-interval` |
| **Slow Keys** | ignora teclas mantenidas < N ms | `xkbset sl N` | `slowkeys-enable` / `slowkeys-delay` |
| **Bounce Keys** | ignora la misma tecla repetida dentro de N ms | `xkbset bo N` | `bouncekeys-enable` / `bouncekeys-delay` |
| **Toggle Keys** | pitido al cambiar Caps/Num/Scroll Lock | retroalimentación AccessX | `togglekeys-enable` |
| **Mouse Keys** | mover el puntero con el teclado numérico | `xkbset m` | `mousekeys-enable` |
| **Gestos** | 5×Shift → Sticky; mantener Shift 8 s → Slow | gestos AccessX | condicionados por `a11y.keyboard enable` |
| **Alto contraste / letra grande** | temas y escalado de texto | tema GTK | `a11y.interface high-contrast`, `interface text-scaling-factor` |
| **Lector de pantalla** | habla la interfaz | Orca (GUI) / speakup (VT) | `a11y.applications screen-reader-enabled` |
| **Magnificador de pantalla** | amplía una región | mutter / KWin / `xzoom` | `a11y.applications screen-magnifier-enabled` |
| **Teclado en pantalla** | entrada de texto por puntero/táctil | OSK de GNOME, GOK (muerto), `xvkbd` | `a11y.applications screen-keyboard-enabled` |
| **Línea braille** | salida táctil | BRLTTY (+ BrlAPI para Orca) | manejada por `brltty`/Orca, no por gsettings |

**Nombres que tenés que saber ubicar:** Orca (lector de pantalla GUI), GOK (teclado en pantalla obsoleto con escaneo), emacspeak (escritorio de audio para Emacs), BRLTTY (demonio braille), speakup (lector de consola en el kernel), espeakup (puentea `speakup_soft` con espeak-ng), speech-dispatcher (multiplexor de TTS), AT-SPI2 (bus D-Bus de accesibilidad), liblouis (tablas de traducción braille), `xkbset` (control de AccessX), `gsettings`/`dconf` (ajustes de GNOME).

---

## 8. Referencias

**Certificación**

* LPI — Objetivos del examen 101-500: https://www.lpi.org/our-certifications/exam-101-objectives/
* LPI — Objetivos del examen 102-500 (el tema 106.3 vive acá): https://www.lpi.org/our-certifications/exam-102-objectives/
* Panorama de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Infraestructura de accesibilidad**

* Lector de pantalla Orca — guía del usuario: https://help.gnome.org/users/orca/stable/
* Orca — código fuente y seguimiento de incidencias: https://gitlab.gnome.org/GNOME/orca
* Núcleo de AT-SPI2: https://gitlab.gnome.org/GNOME/at-spi2-core
* BRLTTY — sitio oficial y manual: https://brltty.app/ · https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
* Speakup — guía de usuario del kernel: https://www.kernel.org/doc/html/latest/admin-guide/spkguide.html
* Speech Dispatcher: https://freebsoft.org/speechd
* eSpeak NG: https://github.com/espeak-ng/espeak-ng
* liblouis (traducción braille): https://liblouis.io/

**Toolkits y servidores gráficos**

* Panorama de accesibilidad de GTK 4: https://docs.gtk.org/gtk4/section-accessibility.html
* Accesibilidad en Qt: https://doc.qt.io/qt-6/accessible.html
* Protocolo X Keyboard Extension (controles AccessX): https://www.x.org/releases/current/doc/kbproto/xkbproto.html
* `xkbset`: https://github.com/stephenmontgomerysmith/xkbset
* libei (capa emergente de emulación de entrada para Wayland): https://libinput.pages.freedesktop.org/libei/
* Permisos del sandbox de Flatpak (`--socket=accessibility`): https://docs.flatpak.org/en/latest/sandbox-permissions.html

**Configuración de flota**

* Guía de administración de sistemas de GNOME (perfiles dconf, bases de datos de sistema, bloqueos): https://help.gnome.org/admin/system-admin-guide/stable/
* `vconsole.conf(5)`: https://www.freedesktop.org/software/systemd/man/vconsole.conf.html
* Reglas de `udev(7)`: https://www.freedesktop.org/software/systemd/man/udev.html
* Manual de GNU GRUB (terminal serie, `GRUB_INIT_TUNE`, fuentes): https://www.gnu.org/software/grub/manual/grub/grub.html
* Guía de instalación de Debian — accesibilidad durante la instalación: https://www.debian.org/releases/stable/amd64/

**Estándares y cumplimiento**

* WCAG 2.2: https://www.w3.org/TR/WCAG22/
* EN 301 549 (ETSI): https://www.etsi.org/deliver/etsi_en/301500_301599/301549/
* Section 508: https://www.section508.gov/
* Convención `NO_COLOR` para salida de CLI: https://no-color.org/