# 106.1 — Instalar y configurar X11

**LPIC-1 · Tema 106: Interfaces de usuario y escritorios**
*(Nota sobre el mapeo del examen: el tema 106 se evalúa en **102-500**, no en 101-500. En el conjunto de objetivos de LPIC-1 v5.0, 106.1 tiene un **peso de 2**. El registro del temario que produjo esta página reporta peso 0.0, lo cual es un hueco de metadatos — estudialo con la profundidad correspondiente a peso 2.)*

---

## 1. Motivación: por qué a un equipo de plataforma todavía le importa X11

La reacción instintiva de un SRE ante "X11" es que le pertenece al equipo de escritorio. Esa reacción es errónea en cuatro contextos de producción que aparecen constantemente:

**a) Cargas de trabajo gráficas headless en CI.** La automatización de navegadores (Selenium, Playwright, Cypress en modo no headless), el empaquetado de Electron, el renderizado de PDF vía Qt/WebKit, ImageMagick con delegados de X, y cualquier arnés de pruebas Java/Swing heredado requieren que exista un servidor X. No requieren una *pantalla*. La respuesta de producción es `Xvfb` o `Xorg` con el driver `dummy` dentro de un contenedor, y el modo de falla — `Error: Can't open display:` — es una de las caídas de CI más comunes en organizaciones con stacks mixtos.

**b) Nodos con GPU.** Un nodo CUDA no necesita X. Un nodo que hace renderizado OpenGL, transcodificación de video con NVENC a través de un pipeline OpenGL, o visualización remota (ParaView, granjas de render de Blender, CAD) sí lo necesita. Configurar `Xorg` en una GPU **sin monitor conectado** requiere `Option "AllowEmptyInitialConfiguration"` y un `BusID` explícito — sin ellos el servidor termina con `no screens found` y el nodo falla silenciosamente en la planificación.

**c) Acceso remoto de ingeniería.** El reenvío de X11 sobre SSH sigue siendo la forma de menor fricción para ejecutar una herramienta gráfica en un host de salto. También es una **decisión de seguridad**: `ssh -Y` le entrega al host remoto acceso total al teclado y a la pantalla de tu sesión local. Conocer la diferencia entre reenvío confiable y no confiable es un control de acceso, no una preferencia de comodidad.

**d) Consola de último recurso y flotas de kioscos.** La cartelería digital, las HMI industriales, las máquinas de banco de laboratorio y las terminales de ticketing son equipos Linux cuyo propósito entero es un cliente X en una pantalla. Se gestionan como servidores, se configuran con fragmentos `xorg.conf.d` desde Ansible, y se depuran por SSH leyendo `~/.xsession-errors`.

### El problema arquitectónico que plantea X11

X11 fue diseñado en 1984 para una red de terminales contra un host central. Dos decisiones de diseño de esa época son hoy los compromisos centrales de producción:

1. **Transparencia de red por defecto.** El protocolo es un flujo de bytes; el transporte (socket UNIX, TCP, túnel SSH) es intercambiable. Por eso `DISPLAY=jump:0` funciona siquiera — y por eso el protocolo de cable es lo bastante conversador como para que una ida y vuelta ingenua sobre 100 ms de RTT vuelva inusable un menú.
2. **Ninguna aislación entre clientes.** Todo cliente conectado a un display puede leer el contenido de las ventanas de cualquier otro cliente, sintetizar eventos de entrada (`XTEST`) y grabar el flujo de entrada (`XRECORD`). No hay modelo de permisos por cliente. Un único cliente X comprometido es un keylogger para toda la sesión. Esta — y no el rendimiento — es la razón por la que existe Wayland.

La decisión de plataforma que realmente te van a pedir tomar es, por lo tanto: *X11, Wayland, o un protocolo de display remoto encima de alguno de los dos* — y X11 sigue ganando exactamente en los casos donde la transparencia de red y 40 años de compatibilidad de clientes importan más que la aislación.

---

## 2. Arquitectura e internals

### 2.1 El modelo cliente/servidor invertido

El **servidor X corre donde está el hardware** — la máquina con el teclado, el mouse y la pantalla. Los **clientes X** son las aplicaciones (`xterm`, Firefox, un gestor de ventanas). Una aplicación remota es un cliente que se conecta *de vuelta* a tu servidor local. Esta inversión es el hecho más confiablemente malentendido de todo el tema.

```
   ┌───────────────────── workstation ──────────────────────┐
   │                                                        │
   │   Xorg (the X SERVER)                                  │
   │     ├── DIX  — device-independent core, protocol,      │
   │     │         request dispatch, event delivery         │
   │     ├── DDX  — device-dependent: modesetting/intel/    │
   │     │         amdgpu/nvidia drivers → DRM/KMS          │
   │     ├── input: libinput → evdev → /dev/input/event*    │
   │     └── extensions: RandR, Composite, GLX, DRI3,       │
   │                     XTEST, XRECORD, SECURITY, XKB      │
   │        ▲            ▲                  ▲               │
   │        │ unix       │ unix             │ TCP :6000+N   │
   │  /tmp/.X11-unix/X0  │              (off by default)    │
   │        │            │                  │               │
   │   window manager  local clients    remote client       │
   │   (mutter/i3/…)   (firefox, …)     via ssh -X tunnel   │
   └────────────────────────────────────────────────────────┘
```

El **gestor de ventanas** (i3, openbox, mutter, kwin) es simplemente otro cliente — es lo que dibuja las barras de título y decide la geometría. El **entorno de escritorio** (GNOME, KDE Plasma, XFCE) es un WM más paneles, un gestor de archivos, demonios de configuración y un gestor de sesión. El **gestor de display** (GDM, LightDM, SDDM, XDM) es el login gráfico: arranca el servidor X, autentica vía PAM, y luego hace exec de la sesión.

### 2.2 Nombres de display, transportes y puertos

```
DISPLAY=hostname:displaynumber.screennumber
```

| Valor | Transporte | Notas |
|---|---|---|
| `:0` o `:0.0` | Socket UNIX `/tmp/.X11-unix/X0` (y socket abstracto `@/tmp/.X11-unix/X0`) | Local, el más rápido, sin stack TCP |
| `unix:0` | Socket UNIX, explícitamente | Fuerza el socket incluso si un hostname resolviera |
| `localhost:10.0` | TCP `127.0.0.1:6010` | La forma de un display reenviado por SSH (`X11DisplayOffset 10`) |
| `10.0.0.5:0` | TCP `10.0.0.5:6000` | Requiere el servidor arrancado con `-listen tcp`; **la cookie viaja en claro** |
| `:1` en un segundo asiento | `/tmp/.X11-unix/X1` | Segunda instancia del servidor, segunda VT |

Puerto TCP = **6000 + número de display**. Desde X.Org 1.17 el servidor usa `-nolisten tcp` por defecto; TCP debe rehabilitarse explícitamente (`Xorg :0 -listen tcp`, o `/etc/X11/xinit/xserverrc`, o la configuración del gestor de display). Tratá rehabilitarlo como una excepción de seguridad que requiere justificación.

### 2.3 Rutas de arranque

Hay exactamente tres formas en que un servidor X se levanta, y tienen superficies de configuración distintas:

| Ruta | Punto de entrada | Configuración de usuario | Dónde va la salida |
|---|---|---|---|
| Manual, desde una VT | `startx` → `xinit` → `Xorg` + script de cliente | `~/.xinitrc`, `~/.xserverrc` (con respaldo en `/etc/X11/xinit/xinitrc`) | La TTY controladora |
| Gestor de display | `display-manager.service` → GDM/LightDM/SDDM → `Xorg` → `Xsession` | `~/.xsession`, `~/.xsessionrc`, `/etc/X11/Xsession.d/*` | `~/.xsession-errors` |
| Headless/servicio | `Xvfb`, o `Xorg` bajo una unidad systemd | solo flags del servidor | journal de la unidad, `-logfile` |

`startx` pasa todo lo que va después de `--` al servidor: `startx -- :1 vt8 -keeptty`.

`~/.xsession-errors` existe porque el wrapper `Xsession` redirige el stdout/stderr de la sesión hacia él (`exec >> "$ERRFILE" 2>&1`). Es el **primer archivo a leer** ante "inicio sesión y me rebota directo al greeter".

### 2.4 El archivo de configuración

X.Org moderno autodetecta casi todo a través de KMS y libinput. `/etc/X11/xorg.conf` es hoy la excepción, y el patrón soportado son los **fragmentos drop-in**:

Orden de búsqueda (lo posterior sobrescribe lo anterior, todo se fusiona):

1. `/usr/share/X11/xorg.conf.d/*.conf` — valores por defecto del proveedor/paquete, **no editar**
2. `/etc/X11/xorg.conf.d/*.conf` — drop-ins del administrador, **editar acá**
3. `/etc/X11/xorg.conf` — archivo monolítico heredado
4. `/etc/xorg.conf`, `/etc/X11/xorg.conf-4`, … — respaldos históricos

Tipos de sección y de qué se ocupa cada una:

| Sección | De qué se ocupa | Uso típico en producción |
|---|---|---|
| `ServerLayout` | Qué Screens e InputDevices forman el layout | Multi-GPU, multi-seat |
| `Files` | `FontPath`, `ModulePath` | Fuentes core heredadas |
| `Module` | Cargar/deshabilitar módulos del servidor | `Disable "dri"` en stacks rotos |
| `InputDevice` | Un dispositivo de entrada estático | Heredado; superado por `InputClass` |
| `InputClass` | Configuración de entrada por coincidencia de reglas | **Distribución de teclado, comportamiento del touchpad** |
| `Device` | La GPU: driver, `BusID`, opciones del driver | GPU headless, NVIDIA, `modesetting` |
| `Monitor` | `HorizSync`, `VertRefresh`, `Modeline`, `DPMS` | Modos forzados, paneles sin EDID |
| `Screen` | Device + Monitor + `SubSection "Display"` (profundidad, `Modes`, `Virtual`) | Tamaño del framebuffer virtual |
| `ServerFlags` | Globales: `DontZap`, `AutoAddDevices`, `BlankTime` | Endurecimiento de kioscos |
| `Extensions` | Habilitar/deshabilitar extensiones del protocolo | `Option "Composite" "Disable"` |

### 2.5 Autorización: quién puede conectarse

| Mecanismo | Granularidad | Seguridad en el cable | Veredicto |
|---|---|---|---|
| `xhost +` | ninguna — **todos en la red** | ninguna | Nunca. Esto es una invitación a la ejecución remota de código |
| `xhost +hostname` | por host, **cualquier usuario en él** | ninguna | Solo dentro de un segmento L2 confiable, temporalmente |
| `xhost +si:localuser:alice` | por UID local (interpretado por el servidor) | n/a (local) | La forma correcta de dejar entrar a un UID local |
| `MIT-MAGIC-COOKIE-1` | secreto compartido de 128 bits por display en `~/.Xauthority` | **texto plano sobre TCP** | Por defecto; seguro sobre socket UNIX o SSH |
| `XDM-AUTHORIZATION-1` | desafío basado en DES | resistente a repetición | Raro, de la era XDMCP |
| Reenvío SSH | por conexión, cookie por sesión | cifrado | **La respuesta de producción** |

El archivo de cookie lo elige `$XAUTHORITY`, con respaldo en `~/.Xauthority`. Los gestores de display frecuentemente lo ubican en otro lado (`/run/user/1000/gdm/Xauthority`), y por eso `sudo` y `su` rompen el acceso a X: el entorno lleva `DISPLAY` pero el nuevo UID no puede leer el archivo de cookie.

### 2.6 Reenvío X11 por SSH, con precisión

Lado servidor (`/etc/ssh/sshd_config`): `X11Forwarding yes`, `X11DisplayOffset 10`, `X11UseLocalhost yes`. El binario `xauth` **debe estar instalado en el servidor** — sshd lo invoca para crear la cookie del proxy. Lado cliente: `ForwardX11`, `ForwardX11Trusted`, `ForwardX11Timeout` (por defecto `20m`).

* `ssh -X` → **no confiable**. sshd genera una cookie restringida por la extensión `SECURITY` y que expira tras `ForwardX11Timeout`. Muchas aplicaciones se rompen bajo este modo (`BadAccess` en `XRECORD`/`XTEST`, rarezas con el portapapeles).
* `ssh -Y` → **confiable**. El cliente remoto tiene acceso total a tu display local: puede capturar la pantalla de tu pestaña bancaria e inyectar pulsaciones de teclas. Usalo solo hacia hosts a los que le darías la contraseña de tu estación de trabajo.

### 2.7 Fuentes

Coexisten dos stacks independientes:

* **Protocolo core de fuentes X** — del lado del servidor, bitmap/Type1, `FontPath` en `Section "Files"`, manipulado en vivo con `xset +fp`/`xset fp rehash`, indexado por `mkfontdir`/`mkfontscale`. Heredado; lo necesitan `xterm`, `xfontsel`, aplicaciones Motif viejas.
* **Xft/fontconfig** — renderizado del lado del cliente con antialiasing, configuración en `/etc/fonts/`, `~/.config/fontconfig/fonts.conf`, caché construida con `fc-cache -fv`, consultada con `fc-list`/`fc-match`. Todo lo moderno usa esto.

Una ruta de fuentes faltante solo produce advertencias `(WW)`; una fuente de fontconfig faltante produce una sustitución de glifos silenciosamente incorrecta — y por eso los renders de PDF en CI salen con la tipografía equivocada sin ningún error.

### 2.8 Conciencia de Wayland (explícitamente evaluable)

Bajo Wayland el compositor **es** el servidor de display: KMS/DRM del kernel + manejo de entrada + gestión de ventanas + composición colapsan en un solo proceso (mutter, kwin_wayland, sway, weston). No hay transparencia de red ni `DISPLAY`; los clientes hablan el protocolo Wayland sobre `$WAYLAND_DISPLAY` en `$XDG_RUNTIME_DIR`. Los clientes X heredados corren bajo **XWayland**, un servidor X sin raíz que se presenta como un `:0` normal y transfiere las superficies al compositor.

| Dimensión | X11 (X.Org) | Wayland |
|---|---|---|
| Arquitectura | Servidor + WM + compositor como procesos separados | Un único proceso compositor |
| Aislación de clientes | **Ninguna** — cualquier cliente lee/inyecta en cualquier lado | Impuesta; captura/entrada requieren portales |
| Transparencia de red | Nativa (TCP / túnel SSH) | Ninguna de forma nativa; `waypipe`, o backends RDP/VNC |
| Captura de pantalla / automatización | Trivial (`xwd`, `xdotool`, `import`) | Requiere `xdg-desktop-portal` + PipeWire |
| Escalado por monitor / DPI mixto | Pobre (DPI global, hacks de RandR) | De primera clase, por salida |
| Libre de tearing por diseño | No (necesita un compositor) | Sí |
| Atajos globales, bloqueadores de pantalla, IMEs | Maduros | Dependientes del protocolo, todavía desparejos |
| Accesibilidad (`AT-SPI`, lectores de pantalla) | Madura | Mejorando, quedan huecos |
| Soporte propietario de NVIDIA | Maduro hace mucho | Bueno desde el driver 495+/sincronización explícita, históricamente doloroso |
| Herramientas de administración remota (`x11vnc`, `ssh -X`) | Funcionan en todos lados | Específicas del compositor |
| Huella en kiosco/embebido | Stack más grande | Más chica (`weston`, `cage`) |

Verificá qué estás corriendo realmente:

```
$ echo "$XDG_SESSION_TYPE"
wayland
$ loginctl show-session "$XDG_SESSION_ID" -p Type -p Remote -p Active
Type=wayland
Remote=no
Active=yes
```

Forzar X11 para una flota que depende de herramientas exclusivas de X: `WaylandEnable=false` en `/etc/gdm/custom.conf` (Debian/Ubuntu: `/etc/gdm3/daemon.conf`), o seleccionar "GNOME on Xorg" por sesión.

### 2.9 Opciones de servidor headless

| Opción | Aceleración GPU | GLX | Cambios de resolución | Costo | Caso de uso |
|---|---|---|---|---|---|
| `Xvfb` | No (software) | Con `+extension GLX` y Mesa `llvmpipe`/`swrast` | Fija al arrancar (`-screen`) | El más bajo | Pruebas de navegador en CI, trabajos de PDF/render |
| `Xorg` + driver `dummy` | No | Software | Capaz de RandR hasta `Virtual` | Bajo | Escritorio headless al que vas a entrar por VNC |
| `Xorg` + GPU real, sin monitor | **Sí** | Hardware | Sí | Necesita `BusID` + `AllowEmptyInitialConfiguration` | Nodos de render con GPU, visualización remota |
| `Xephyr` / `Xnest` | Anidado en un X existente | GLX en `Xephyr` | Redimensionable | Trivial | Depurar un WM/sesión sin salir de tu escritorio |

### 2.10 Protocolos de display remoto

| Protocolo | Modelo | Estado al desconectar | Ancho de banda con video | Portapapeles/audio | Multiusuario | GPU |
|---|---|---|---|---|---|---|
| Reenvío X11 (`ssh -X/-Y`) | Por aplicación, síncrono | **Perdido** — la app muere con el túnel | Pobre (limitado por ida y vuelta) | Portapapeles sí, audio no | Por usuario | Solo GLX indirecto |
| VNC (`x11vnc`, TigerVNC) | Espejo del framebuffer | Persiste (sesión del lado del servidor) | Moderado (Tight/ZRLE) | Portapapeles sí, audio no | Por display | Vía virtualGL |
| RDP (`xrdp`, FreeRDP) | Híbrido semántico + bitmap | Persiste, amigable a la reconexión | Bueno (RemoteFX/H.264) | Portapapeles, audio, redirección de unidades | Sí, por sesión | Sí |
| NX / X2Go | Compresión del protocolo X + proxy | Sesiones suspender/reanudar | Bueno | Sí | Sí | Limitado |
| SPICE | Orientado a VM | Persiste (del lado de la VM) | Bueno | Sí | Con alcance de VM | Sí |
| `waypipe` | Wayland sobre SSH | Se pierde con el túnel | Bueno (consciente de dmabuf) | Parcial | Por usuario | Sí |

Regla práctica para trabajo de plataforma: **`ssh -X` para una herramienta, VNC/RDP para una sesión duradera, nunca `xhost +` para nada.**

---

## 3. Configuraciones completas e infraestructura

### 3.1 Drop-in de distribución de teclado — `/etc/X11/xorg.conf.d/00-keyboard.conf`

Este es exactamente el archivo que escribe `localectl set-x11-keymap`; también es la respuesta canónica a "sobrescribir un aspecto de la configuración de Xorg".

```
# Written by systemd-localed(8) or by configuration management.
# Keep in sync with /etc/vconsole.conf so console and X agree.
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "us,es"
        Option "XkbModel" "pc105"
        Option "XkbVariant" "intl,"
        Option "XkbOptions" "grp:alt_shift_toggle,terminate:ctrl_alt_bksp,compose:ralt"
EndSection
```

### 3.2 Touchpad y puntero — `/etc/X11/xorg.conf.d/40-libinput-touchpad.conf`

```
Section "InputClass"
        Identifier "libinput touchpad catchall"
        MatchIsTouchpad "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
        Option "Tapping" "on"
        Option "TappingButtonMap" "lrm"
        Option "NaturalScrolling" "true"
        Option "ScrollMethod" "twofinger"
        Option "DisableWhileTyping" "true"
        Option "AccelProfile" "adaptive"
        Option "AccelSpeed" "0.3"
EndSection

Section "InputClass"
        Identifier "libinput pointer catchall"
        MatchIsPointer "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
        # Flat profile: 1:1 motion, required for CAD and remote-desktop work
        Option "AccelProfile" "flat"
EndSection
```

### 3.3 X headless sobre una GPU real — `/etc/X11/xorg.conf` completo

Para un nodo de renderizado con una placa NVIDIA y **ningún monitor enchufado**. Sin `AllowEmptyInitialConfiguration` el servidor aborta con `no screens found`.

```
Section "ServerLayout"
        Identifier     "headless-render"
        Screen      0  "Screen0" 0 0
        Option         "AutoAddDevices" "false"
        Option         "AutoAddGPU"     "false"
EndSection

Section "ServerFlags"
        Option         "DontVTSwitch"   "true"
        Option         "DontZap"        "true"
        Option         "AllowMouseOpenFail" "true"
        Option         "BlankTime"      "0"
        Option         "StandbyTime"    "0"
        Option         "SuspendTime"    "0"
        Option         "OffTime"        "0"
EndSection

Section "Files"
        ModulePath     "/usr/lib/xorg/modules"
        FontPath       "/usr/share/fonts/X11/misc"
        FontPath       "built-ins"
EndSection

Section "Module"
        Load           "glx"
        Load           "dri2"
EndSection

Section "Monitor"
        Identifier     "Monitor0"
        VendorName     "Unknown"
        ModelName      "Virtual"
        HorizSync       28.0 - 90.0
        VertRefresh     43.0 - 75.0
        # Generated by: cvt 1920 1080 60
        Modeline       "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
        Option         "DPMS" "false"
EndSection

Section "Device"
        Identifier     "Device0"
        Driver         "nvidia"
        VendorName     "NVIDIA Corporation"
        BusID          "PCI:1:0:0"
        Option         "AllowEmptyInitialConfiguration" "true"
        Option         "UseDisplayDevice" "none"
        Option         "ConnectedMonitor" "DFP-0"
        Option         "CustomEDID" "DFP-0:/etc/X11/edid.bin"
EndSection

Section "Screen"
        Identifier     "Screen0"
        Device         "Device0"
        Monitor        "Monitor0"
        DefaultDepth    24
        Option         "UseDisplayDevice" "none"
        SubSection     "Display"
                Depth       24
                Modes      "1920x1080_60.00"
                Virtual     3840 2160
        EndSubSection
EndSection

Section "Extensions"
        Option         "Composite" "Disable"
EndSection
```

### 3.4 Headless puramente por software — `/etc/X11/xorg.conf.d/10-dummy.conf`

```
Section "Device"
        Identifier  "dummy-gpu"
        Driver      "dummy"
        # 256 MB is enough for 3840x2160x32 with room for pixmaps
        VideoRam    256000
EndSection

Section "Monitor"
        Identifier  "dummy-monitor"
        HorizSync    5.0 - 1000.0
        VertRefresh  5.0 - 200.0
        Modeline    "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
        Modeline    "3840x2160_60.00" 712.75 3840 4160 4576 5312 2160 2163 2168 2237 -hsync +vsync
EndSection

Section "Screen"
        Identifier  "dummy-screen"
        Device      "dummy-gpu"
        Monitor     "dummy-monitor"
        DefaultDepth 24
        SubSection  "Display"
                Depth   24
                Modes  "1920x1080_60.00" "3840x2160_60.00"
                Virtual 3840 2160
        EndSubSection
EndSection
```

### 3.5 Wrapper de X sin raíz — `/etc/X11/Xwrapper.config`

```
# allowed_users: console | rootonly | anybody
# needs_root_rights: yes | no | auto   (auto = drop root when KMS allows it)
allowed_users=console
needs_root_rights=auto
```

Con `needs_root_rights=auto` sobre un driver KMS, Xorg corre sin privilegios y su log se muda a `~/.local/share/xorg/Xorg.0.log`. Mirar en `/var/log/Xorg.0.log` en un sistema así devuelve un archivo obsoleto de la última ejecución como root — una trampa clásica que hace perder horas.

### 3.6 Unidad plantilla de systemd para un display virtual — `/etc/systemd/system/xvfb@.service`

```ini
[Unit]
Description=X Virtual Frame Buffer on display %i
Documentation=man:Xvfb(1)
After=network.target
StopWhenUnneeded=yes

[Service]
Type=simple
User=xvfb
Group=xvfb
Environment=XVFB_RES=1920x1080x24
ExecStart=/usr/bin/Xvfb :%i \
          -screen 0 ${XVFB_RES} \
          -nolisten tcp \
          -nolisten unix \
          -auth /run/xvfb/Xauthority.%i \
          -dpi 96 \
          +extension GLX +extension RANDR +extension RENDER \
          -noreset
ExecStartPre=/usr/bin/install -d -o xvfb -g xvfb -m 0750 /run/xvfb
Restart=on-failure
RestartSec=2s

# Hardening: this process needs no privileges at all
NoNewPrivileges=yes
PrivateTmp=no
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/run/xvfb /tmp/.X11-unix
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX
CapabilityBoundingSet=
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
```

Los consumidores declaran `Requires=xvfb@99.service` y definen `Environment=DISPLAY=:99`. `-noreset` es esencial: sin él el servidor se reinicia (y borra el estado de la ventana raíz) cada vez que el último cliente se desconecta, lo que rompe las grillas de pruebas de larga duración.

### 3.7 Rol de Ansible — desplegar la política de X11 a una flota de kiosco/CI

```yaml
---
# roles/x11_baseline/tasks/main.yml
- name: Install the minimal X stack
  ansible.builtin.package:
    name:
      - xserver-xorg-core
      - xserver-xorg-video-dummy
      - xserver-xorg-input-libinput
      - xvfb
      - x11-xserver-utils     # xset, xrandr, xhost
      - x11-utils             # xdpyinfo, xwininfo, xev
      - xauth
      - fonts-dejavu-core
    state: present

- name: Ensure the drop-in directory exists
  ansible.builtin.file:
    path: /etc/X11/xorg.conf.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy keyboard layout drop-in
  ansible.builtin.template:
    src: 00-keyboard.conf.j2
    dest: /etc/X11/xorg.conf.d/00-keyboard.conf
    owner: root
    group: root
    mode: "0644"
    validate: /bin/true          # Xorg has no offline syntax checker; see verification below
  notify: restart display manager

- name: Deploy the dummy device drop-in on headless hosts
  ansible.builtin.copy:
    src: 10-dummy.conf
    dest: /etc/X11/xorg.conf.d/10-dummy.conf
    owner: root
    group: root
    mode: "0644"
  when: x11_headless | bool
  notify: restart display manager

- name: Forbid host-based X authorization fleet-wide
  ansible.builtin.copy:
    dest: /etc/profile.d/zz-no-xhost.sh
    owner: root
    group: root
    mode: "0644"
    content: |
      # Host-based X authorization grants every user on the peer host full
      # access to this display, including keystroke capture. Blocked by policy.
      xhost() {
          echo "xhost is disabled by policy; use xauth or ssh -X" >&2
          return 1
      }

- name: Console and X keymaps must agree
  ansible.builtin.command:
    cmd: >-
      localectl set-x11-keymap
      {{ x11_layout }} {{ x11_model }} {{ x11_variant | default('') }}
      {{ x11_options | default('') }}
  register: _localectl
  changed_when: _localectl.rc == 0
  when: x11_manage_keymap | bool

- name: Enable the virtual framebuffer on CI runners
  ansible.builtin.systemd:
    name: "xvfb@{{ x11_vfb_display }}.service"
    enabled: true
    state: started
    daemon_reload: true
  when: x11_role == 'ci-runner'

- name: Assert that the display actually answers
  ansible.builtin.command:
    cmd: "xdpyinfo -display :{{ x11_vfb_display }}"
  register: _xdpy
  changed_when: false
  failed_when: "'number of screens' not in _xdpy.stdout"
  when: x11_role == 'ci-runner'
```

```yaml
---
# roles/x11_baseline/defaults/main.yml
x11_headless: true
x11_manage_keymap: true
x11_layout: "us"
x11_model: "pc105"
x11_variant: ""
x11_options: "terminate:ctrl_alt_bksp"
x11_role: "ci-runner"
x11_vfb_display: 99
```

```yaml
---
# roles/x11_baseline/handlers/main.yml
- name: restart display manager
  ansible.builtin.systemd:
    name: display-manager.service
    state: restarted
  when:
    - not (x11_headless | bool)
    - x11_allow_session_restart | default(false) | bool
```

### 3.8 Kubernetes: ejecutor de pruebas gráficas con un sidecar Xvfb

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: xvfb-config
  namespace: ci
data:
  DISPLAY: ":99"
  SCREEN_GEOMETRY: "1920x1080x24"
  XAUTHORITY: "/tmp/.xauth/Xauthority"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: browser-grid
  namespace: ci
  labels:
    app.kubernetes.io/name: browser-grid
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: browser-grid
  template:
    metadata:
      labels:
        app.kubernetes.io/name: browser-grid
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      volumes:
        # The X server socket lives here; both containers must see it.
        - name: x11-socket
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
        - name: xauth
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
        # Chromium crashes with "Failed to move to new namespace" / tab
        # crashes when /dev/shm is the 64Mi container default.
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
      containers:
        - name: xvfb
          image: registry.example.com/ci/xvfb:1.21.1-r4
          imagePullPolicy: IfNotPresent
          command: ["/usr/bin/Xvfb"]
          args:
            - ":99"
            - "-screen"
            - "0"
            - "1920x1080x24"
            - "-nolisten"
            - "tcp"
            - "-dpi"
            - "96"
            - "+extension"
            - "GLX"
            - "+extension"
            - "RANDR"
            - "+extension"
            - "RENDER"
            - "-noreset"
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: xauth
              mountPath: /tmp/.xauth
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            exec:
              command: ["/usr/bin/xdpyinfo", "-display", ":99"]
            initialDelaySeconds: 1
            periodSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec:
              command: ["/usr/bin/xdpyinfo", "-display", ":99"]
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

        - name: runner
          image: registry.example.com/ci/playwright:1.44.0
          envFrom:
            - configMapRef:
                name: xvfb-config
          env:
            - name: LIBGL_ALWAYS_SOFTWARE
              value: "1"
            - name: GALLIUM_DRIVER
              value: "llvmpipe"
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: xauth
              mountPath: /tmp/.xauth
            - name: dshm
              mountPath: /dev/shm
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "2"
              memory: 4Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]

        # Debug-only: attach a VNC view of the virtual screen.
        # Keep replicas of this Deployment inside a private namespace.
        - name: x11vnc
          image: registry.example.com/ci/x11vnc:0.9.16-r2
          args:
            - "-display"
            - ":99"
            - "-forever"
            - "-shared"
            - "-localhost"
            - "-rfbport"
            - "5900"
            - "-nopw"
          ports:
            - name: vnc
              containerPort: 5900
          volumeMounts:
            - name: x11-socket
              mountPath: /tmp/.X11-unix
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

`-localhost` en `x11vnc` más la ausencia de un Service para el puerto 5900 significa que la vista de depuración solo es alcanzable a través de `kubectl port-forward` — el pod nunca expone un framebuffer sin autenticación en la red del clúster.

### 3.9 Imagen mínima de Xvfb

```dockerfile
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb \
        x11-utils \
        xauth \
        libgl1-mesa-dri \
        libglx-mesa0 \
        fonts-dejavu-core \
        fonts-liberation; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -m 1777 /tmp/.X11-unix

RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin xvfb
USER 1000:1000

ENV DISPLAY=:99
ENTRYPOINT ["/usr/bin/Xvfb"]
CMD [":99", "-screen", "0", "1920x1080x24", "-nolisten", "tcp", "-noreset"]
```

---

## 4. Línea de comandos: invocaciones reales y salidas reales

### 4.1 Identificar la sesión y el servidor

```
$ echo "$DISPLAY $XAUTHORITY $XDG_SESSION_TYPE"
:0 /run/user/1000/gdm/Xauthority x11

$ loginctl list-sessions
SESSION  UID USER     SEAT  TTY
      2 1000 dalmine  seat0 tty2
      c1  120 gdm      seat0 tty1

2 sessions listed.

$ loginctl show-session 2 -p Type -p Class -p Active -p Display
Type=x11
Class=user
Active=yes
Display=:0

$ systemctl status display-manager.service --no-pager | head -4
● gdm.service - GNOME Display Manager
     Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: enabled)
     Active: active (running) since Wed 2026-08-26 08:11:44 -03; 6h 2min ago
   Main PID: 1188 (gdm)
```

### 4.2 Inspeccionar el display

```
$ xdpyinfo | head -20
name of display:    :0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12101011
X.Org version: 21.1.11
maximum request size:  16777212 bytes
motion buffer size:  256
bitmap unit, bit order, padding:    32, LSBFirst, 32
image byte order:    LSBFirst
number of supported pixmap formats:    7
supported pixmap formats:
    depth 1, bits_per_pixel 1, scanline_pad 32
    depth 4, bits_per_pixel 8, scanline_pad 32
    depth 8, bits_per_pixel 8, scanline_pad 32
    depth 15, bits_per_pixel 16, scanline_pad 32
    depth 16, bits_per_pixel 16, scanline_pad 32
    depth 24, bits_per_pixel 32, scanline_pad 32
    depth 32, bits_per_pixel 32, scanline_pad 32
keycode range:    minimum 8, maximum 255
focus:  window 0x4000007, revert to Parent

$ xdpyinfo | grep -E 'dimensions|resolution|depth of root'
  dimensions:    3840x1080 pixels (1016x286 millimeters)
  resolution:    96x96 dots per inch
  depth of root window:    24 planes

$ xdpyinfo -queryExtensions | grep -E '^(RANDR|GLX|Composite|XTEST|SECURITY|DRI3|XKEYBOARD)'
RANDR  (opcode: 140, base event: 89, base error: 147)
GLX  (opcode: 152, base event: 95, base error: 158)
Composite  (opcode: 142)
XTEST  (opcode: 130)
SECURITY  (opcode: 137, base event: 96, base error: 166)
DRI3  (opcode: 149)
XKEYBOARD  (opcode: 135, base event: 85, base error: 137)
```

### 4.3 Salidas y modos con RandR

```
$ xrandr --query
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm
   1920x1080     60.02*+  60.01    59.97    59.96    59.93
   1680x1050     59.95    59.88
   1280x1024     60.02
   1024x768      60.04    60.00
HDMI-1 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+  50.00    59.94
   1680x1050     59.88
   1280x720      60.00    50.00    59.94
DP-1 disconnected (normal left inverted right x axis y axis)
DP-2 disconnected (normal left inverted right x axis y axis)

$ xrandr --output HDMI-1 --mode 1920x1080 --rate 60 --right-of eDP-1 --primary

$ xrandr --output HDMI-1 --off
```

Agregar un modo que el EDID nunca anunció (típico con switches KVM y tiradas largas de HDMI):

```
$ cvt 2560 1440 60
# 2560x1440 59.96 Hz (CVT 3.69M9) hsync: 89.52 kHz; pclk: 312.25 MHz
Modeline "2560x1440_60.00"  312.25  2560 2752 3024 3488  1440 1443 1448 1493 -hsync +vsync

$ xrandr --newmode "2560x1440_60.00" 312.25 2560 2752 3024 3488 1440 1443 1448 1493 -hsync +vsync
$ xrandr --addmode DP-1 "2560x1440_60.00"
$ xrandr --output DP-1 --mode "2560x1440_60.00"
```

### 4.4 Preferencias del servidor: `xset`

```
$ xset q
Keyboard Control:
  auto repeat:  on    key click percent:  0    LED mask:  00000002
  XKB indicators:
    00: Caps Lock:   off    01: Num Lock:    on     02: Scroll Lock: off
  auto repeat delay:  500    repeat rate:  33
  bell percent:  50    bell pitch:  400    bell duration:  100
Pointer Control:
  acceleration:  2/1    threshold:  4
Screen Saver:
  prefer blanking:  yes    allow exposures:  yes
  timeout:  600    cycle:  600
Colors:
  default colormap:  0x20    BlackPixel:  0x0    WhitePixel:  0xffffff
Font Path:
  /usr/share/fonts/X11/misc,/usr/share/fonts/X11/Type1,built-ins
DPMS (Display Power Management Signaling):
  Standby: 600    Suspend: 900    Off: 1200
  DPMS is Enabled
  Monitor is On

# Kiosk/signage: never blank the panel
$ xset s off -dpms
$ xset s noblank

# Add a legacy core font directory at runtime
$ xset +fp /usr/share/fonts/X11/100dpi
$ xset fp rehash
```

### 4.5 Autorización

```
$ xauth list
workstation/unix:0  MIT-MAGIC-COOKIE-1  8f4c0b2e1a9d47f3b5c6e8d0a1234567
workstation/unix:10 MIT-MAGIC-COOKIE-1  b71ee9c4a05f3d82e6114c7fa9930bc2

$ xauth -f /run/user/1000/gdm/Xauthority list
workstation/unix:0  MIT-MAGIC-COOKIE-1  8f4c0b2e1a9d47f3b5c6e8d0a1234567

# Hand the cookie for :0 to another local account, safely
$ xauth extract - "$DISPLAY" | sudo -u builder env XAUTHORITY=/home/builder/.Xauthority xauth merge -
$ sudo -u builder env DISPLAY=:0 XAUTHORITY=/home/builder/.Xauthority xdpyinfo | head -1
name of display:    :0

# Mint a fresh, time-limited, untrusted cookie
$ xauth generate :0 . untrusted timeout 600

# Remove a stale entry after a server restart
$ xauth remove :0

# Host-based access — shown for completeness; do not use
$ xhost
access control enabled, only authorized clients can connect
$ xhost +si:localuser:builder
localuser:builder being added to access control list
```

### 4.6 Dispositivos de entrada y mapa de teclado

```
$ xinput list
⎡ Virtual core pointer                        id=2    [master pointer  (3)]
⎜   ↳ Virtual core XTEST pointer              id=4    [slave  pointer  (2)]
⎜   ↳ SynPS/2 Synaptics TouchPad              id=12   [slave  pointer  (2)]
⎜   ↳ Logitech USB Receiver Mouse             id=15   [slave  pointer  (2)]
⎣ Virtual core keyboard                       id=3    [master keyboard (2)]
    ↳ Virtual core XTEST keyboard             id=5    [slave  keyboard (3)]
    ↳ AT Translated Set 2 keyboard            id=11   [slave  keyboard (3)]
    ↳ Video Bus                               id=8    [slave  keyboard (3)]

$ xinput list-props 12 | head -12
Device 'SynPS/2 Synaptics TouchPad':
        Device Enabled (191):   1
        Coordinate Transformation Matrix (193): 1.000000, 0.000000, 0.000000, 0.000000, 1.000000, 0.000000, 0.000000, 0.000000, 1.000000
        libinput Tapping Enabled (330): 1
        libinput Tapping Enabled Default (331):  0
        libinput Natural Scrolling Enabled (334): 1
        libinput Accel Speed (338): 0.300000
        libinput Accel Profile Enabled (342): 1, 0

$ setxkbmap -query
rules:      evdev
model:      pc105
layout:     us,es
variant:    intl,
options:    grp:alt_shift_toggle,terminate:ctrl_alt_bksp

$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us,es
       X11 Model: pc105
     X11 Variant: intl,
     X11 Options: grp:alt_shift_toggle,terminate:ctrl_alt_bksp

$ sudo localectl set-x11-keymap us,es pc105 intl, grp:alt_shift_toggle
$ cat /etc/X11/xorg.conf.d/00-keyboard.conf
# Written by systemd-localed(8), read by systemd-localed and Xorg. It's
# probably wise not to edit this file manually. Use localectl(1) to
# instruct systemd-localed to update it.
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "us,es"
        Option "XkbModel" "pc105"
        Option "XkbVariant" "intl,"
        Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
```

### 4.7 Stack de renderizado

```
$ glxinfo -B
name of display: :0
display: :0  screen: 0
direct rendering: Yes
Extended renderer info (GLX_MESA_query_renderer):
    Vendor: Intel (0x8086)
    Device: Mesa Intel(R) UHD Graphics 620 (KBL GT2) (0x5917)
    Version: 23.2.1
    Accelerated: yes
    Video memory: 15774MB
    Unified memory: yes
    Preferred profile: core (0x1)
    Max core profile version: 4.6
    Max compat profile version: 4.6
OpenGL vendor string: Intel
OpenGL renderer string: Mesa Intel(R) UHD Graphics 620 (KBL GT2)
OpenGL core profile version string: 4.6 (Core Profile) Mesa 23.2.1-1

# Software fallback inside a container without /dev/dri
$ LIBGL_ALWAYS_SOFTWARE=1 glxinfo -B | grep -E 'renderer|direct'
direct rendering: Yes
OpenGL renderer string: llvmpipe (LLVM 15.0.6, 256 bits)
```

### 4.8 Sockets, listeners, clientes

```
$ ls -l /tmp/.X11-unix/
total 0
srwxrwxrwx. 1 root root 0 Aug 26 08:11 X0
srwxrwxrwx. 1 ci   ci   0 Aug 26 09:03 X99

$ ss -ltnp | grep -E ':60[0-9][0-9]'
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=48211,fd=9))

$ sudo lsof /tmp/.X11-unix/X0 | head -5
COMMAND    PID    USER   FD   TYPE             DEVICE SIZE/OFF     NODE NAME
Xorg      1402     ci    1u  unix 0x0000000012a4f100      0t0    31245 /tmp/.X11-unix/X0
firefox   3311 dalmine   38u  unix 0x0000000018bb2c40      0t0    41902 /tmp/.X11-unix/X0

$ xlsclients -l | head -8
Window 0x2c00003:
  Machine:  workstation
  Name:  Alacritty
  Icon Name:  Alacritty
  Class:  Alacritty
Window 0x3200005:
  Machine:  workstation
  Name:  Mozilla Firefox
```

### 4.9 Verificación headless de punta a punta

```
$ Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp -noreset &
[1] 20144

$ DISPLAY=:99 xdpyinfo | grep -E 'name of display|dimensions|depths'
name of display:    :99
  dimensions:    1920x1080 pixels (487x274 millimeters)
  depths (7):    24, 1, 4, 8, 15, 16, 32

$ DISPLAY=:99 xrandr --query
Screen 0: minimum 1920 x 1080, current 1920 x 1080, maximum 1920 x 1080
default connected 1920x1080+0+0 0mm x 0mm
   1920x1080     0.00*

$ xvfb-run -a --server-args="-screen 0 1280x1024x24 -nolisten tcp" \
      /opt/app/run-ui-tests.sh
Running 42 tests using 4 workers
  42 passed (1.4m)

$ DISPLAY=:99 xwd -root -silent | convert xwd:- /tmp/screen.png
$ identify /tmp/screen.png
/tmp/screen.png PNG 1920x1080 1920x1080+0+0 8-bit sRGB 12.4KB 0.000u 0:00.000
```

### 4.10 Reenvío

```
$ ssh -X ops@buildhost 'echo $DISPLAY; xdpyinfo | head -1'
localhost:10.0
name of display:    localhost:10.0

$ ssh -v -X ops@buildhost xterm 2>&1 | grep -i x11
debug1: Requesting X11 forwarding with authentication spoofing.
debug1: Requesting authentication agent forwarding.

# Verbose sshd side, when it fails:
$ sudo journalctl -u sshd -n 5 --no-pager
Aug 26 14:02:11 buildhost sshd[52011]: error: Failed to allocate internet-domain X11 display socket.
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Validar un cambio de configuración *antes* de que te cueste la sesión

X.Org **no tiene verificador de sintaxis offline**. Reiniciar el gestor de display para probar un fragmento de `xorg.conf.d` arriesga dejar afuera a todos los usuarios con sesión iniciada. El procedimiento seguro:

```
# 1. Parse-check by starting a throwaway server on a spare VT and display
$ sudo Xorg :3 vt9 -config /etc/X11/xorg.conf -configdir /etc/X11/xorg.conf.d \
        -logfile /tmp/Xorg.3.log -novtswitch -noreset &

# 2. Prove it came up
$ DISPLAY=:3 xdpyinfo | head -1
name of display:    :3

# 3. Read only the interesting lines
$ grep -E '\((EE|WW)\)' /tmp/Xorg.3.log
[   112.884] (WW) The directory "/usr/share/fonts/X11/cyrillic" does not exist.
[   112.884] (WW) Warning, couldn't open module "nv"

# 4. Tear it down
$ sudo pkill -f 'Xorg :3'
```

Generador heredado, todavía evaluable — debe ejecutarse con **ningún servidor X activo** y como root, y escribe en el directorio actual:

```
$ sudo systemctl isolate multi-user.target
$ sudo Xorg -configure
Number of created screens does not match number of detected devices.
  Configuration failed.
$ ls -l /root/xorg.conf.new
```

(Que `Xorg -configure` falle en un sistema KMS moderno es normal, no una falla — escribí a mano un drop-in en su lugar.)

### 5.2 Leer el log

La ubicación depende de si Xorg corre como root:

| Situación | Ruta del log |
|---|---|
| Xorg ejecutado como root (heredado, o `needs_root_rights=yes`) | `/var/log/Xorg.<display>.log` |
| Xorg sin raíz (predeterminado moderno) | `~/.local/share/xorg/Xorg.<display>.log` |
| Bajo un gestor de display, antes del login | `/var/log/Xorg.0.log` o el home del usuario del greeter |
| Bajo unidad systemd / contenedor | journal de la unidad o el destino de `-logfile` |

Marcadores de línea:

| Marcador | Significado |
|---|---|
| `(--)` | Detectado del hardware |
| `(**)` | Del archivo de configuración |
| `(==)` | Valor por defecto |
| `(++)` | De la línea de comandos |
| `(II)` | Informativo |
| `(WW)` | Advertencia — normalmente sobrevivible |
| `(EE)` | **Error** — empezá por acá |
| `(NI)` | No implementado |
| `(??)` | Desconocido |

Triage rápido:

```
$ grep -E '\(EE\)' ~/.local/share/xorg/Xorg.0.log
[    32.398] (EE) Failed to load module "nvidia" (module does not exist, 0)
[    33.021] (EE) No devices detected.
[    33.022] (EE) Screen(s) found, but none have a usable configuration.
[    33.022] (EE) Fatal server error:
[    33.022] (EE) no screens found(EE)
[    33.022] (EE) Please consult the The X.Org Foundation support at http://wiki.x.org
[    33.022] (EE) Please also check the log file at "/home/ci/.local/share/xorg/Xorg.0.log"

$ grep -E 'Loading|LoadModule' ~/.local/share/xorg/Xorg.0.log | tail -6
[    31.902] (II) LoadModule: "modesetting"
[    31.903] (II) Loading /usr/lib/xorg/modules/drivers/modesetting_drv.so
[    31.910] (II) LoadModule: "libinput"
[    31.911] (II) Loading /usr/lib/xorg/modules/input/libinput_drv.so
```

### 5.3 El árbol de decisión de `Can't open display`

Cada falla de conexión a X produce uno de cinco mensajes distinguibles. Emparejá el mensaje, no el síntoma.

| Mensaje | Causa raíz | Solución |
|---|---|---|
| `Error: Can't open display:` (vacío) | `DISPLAY` no está definido | `export DISPLAY=:0` — y averiguá por qué falta el entorno de sesión (cron, unidad systemd, `su -`) |
| `Can't open display: :0` con un servidor corriendo | El cliente no puede alcanzar el socket (namespace, `PrivateTmp=yes`, contenedor sin el socket montado) | Montá `/tmp/.X11-unix`; sacá `PrivateTmp` |
| `Authorization required, but no authorization protocol specified` | No se encontró cookie — `XAUTHORITY` sin definir o ilegible para este UID | `export XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority`, o `xauth merge` para el usuario destino |
| `Invalid MIT-MAGIC-COOKIE-1 key` | Existe una cookie pero está obsoleta (el servidor se reinició) o pertenece a otro display | `xauth remove :0 && xauth generate :0 .` |
| `X11 connection rejected because of wrong authentication` | La ruta de reenvío SSH está rota | Ver 5.5 |
| `connect /tmp/.X11-unix/X0: Connection refused` | No hay servidor en ese número de display | `pgrep -a Xorg\|Xvfb`; revisá la unidad |

Secuencia de diagnóstico:

```
$ echo "DISPLAY=[$DISPLAY] XAUTHORITY=[$XAUTHORITY]"
DISPLAY=[:0] XAUTHORITY=[]

$ pgrep -a 'Xorg|Xwayland|Xvfb'
1402 /usr/lib/xorg/Xorg vt2 -displayfd 3 -auth /run/user/1000/gdm/Xauthority -background none -noreset -keeptty -novtswitch -verbose 3

# The -auth argument on the running server IS the authoritative cookie path
$ export XAUTHORITY=/run/user/1000/gdm/Xauthority
$ xdpyinfo | head -1
name of display:    :0
```

### 5.4 `sudo` y `su` pierden el display

```
$ sudo xclock
No protocol specified
Error: Can't open display: :0
```

El entorno conservó `DISPLAY` pero root no puede leer tu archivo de cookie (o `env_reset` descartó `XAUTHORITY` por completo). Tres soluciones correctas, en orden de preferencia:

```
# 1) Don't run GUI apps as root. Use pkexec / polkit for the privileged action only.
$ pkexec /usr/sbin/gparted

# 2) Pass the cookie explicitly, one command, no persistent grant
$ sudo env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" xclock

# 3) Allow the target local UID at the server, then revoke
$ xhost +si:localuser:root
localuser:root being added to access control list
$ sudo xclock
$ xhost -si:localuser:root
```

`xhost +local:` o `xhost +` "arreglan" el síntoma deshabilitando por completo el control de acceso — marcá esto en la revisión de código.

### 5.5 Escalera de fallas del reenvío X11 por SSH

Probá cada escalón; la primera falla es la causa.

```
# Rung 1 — is forwarding on at the server?
$ ssh ops@buildhost 'sudo sshd -T | grep -Ei "x11forwarding|x11displayoffset|x11uselocalhost"'
x11forwarding yes
x11displayoffset 10
x11uselocalhost yes

# Rung 2 — is xauth installed on the server? sshd shells out to it.
$ ssh ops@buildhost 'command -v xauth || echo MISSING'
/usr/bin/xauth

# Rung 3 — did the client actually request forwarding?
$ ssh -X -v ops@buildhost true 2>&1 | grep -i 'X11 forwarding'
debug1: Requesting X11 forwarding with authentication spoofing.

# Rung 4 — is DISPLAY set inside the remote session?
$ ssh -X ops@buildhost 'echo ${DISPLAY:-UNSET}'
localhost:10.0

# Rung 5 — does the remote proxy have a cookie?
$ ssh -X ops@buildhost 'xauth list'
buildhost/unix:10  MIT-MAGIC-COOKIE-1  4bd11a95e30fc7268a5f0912de37cc41

# Rung 6 — does a client actually connect?
$ ssh -X ops@buildhost 'xdpyinfo | head -1'
name of display:    localhost:10.0
```

Firmas de falla:

| Síntoma | Causa |
|---|---|
| `DISPLAY` está UNSET, el log de sshd dice `Failed to allocate internet-domain X11 display socket` | Desajuste con `AddressFamily inet6`/IPv6 deshabilitado, o los puertos 6010+ ya están ocupados; también se ve cuando `X11UseLocalhost no` y no hay dirección a la cual asociarse |
| El reenvío funciona 20 minutos y después muere | `ForwardX11Timeout` (por defecto `20m`) hizo expirar la cookie no confiable — usá `ssh -Y` deliberadamente, o subí el timeout |
| `BadAccess (attempt to access private resource denied)` en una aplicación específica | Modo no confiable (`-X`) bloqueando `XTEST`/`XRECORD`/`Composite` — la aplicación necesita `-Y` |
| Funciona como tu usuario, falla después de `sudo -i` en el remoto | El mismo problema de propiedad de la cookie que en 5.4, del otro lado |

### 5.6 La sesión arranca y muere de inmediato

```
$ tail -30 ~/.xsession-errors
/etc/X11/Xsession.d/40x11-common_xsessionrc: line 8: /home/dalmine/.xsessionrc: Permission denied
localuser:dalmine being added to access control list
openConnection: connect: No such file or directory
cannot connect to brltty at :0
gnome-session-binary[4102]: WARNING: Could not parse desktop file custom.desktop
gnome-session-binary[4102]: CRITICAL: We failed, but the fail whale is dead. Sorry....
```

Lista de verificación:

1. `~/.xsession-errors` — scripts a nivel de sesión y caídas del DE.
2. `journalctl -b -u gdm` (o `lightdm`/`sddm`) — fallas del greeter y de PAM.
3. `journalctl -b _COMM=gnome-shell` — caídas del compositor.
4. `ls -ld ~ ~/.Xauthority ~/.config` — un directorio home cuyo dueño es el UID equivocado, o lleno, rompe el login exactamente de esta forma.
5. `df -h ~ && quota -s` — un `$HOME` lleno no puede escribir `.Xauthority`; el login entra en bucle silenciosamente.
6. Reproducí con una sesión mínima: `startx /usr/bin/xterm -- :2 vt9` — si un `xterm` pelado funciona, la falla está en el DE, no en X.

### 5.7 Sin pantallas / resolución incorrecta

```
$ grep -E 'Output|EDID|Modeline|no screens' ~/.local/share/xorg/Xorg.0.log | head
[    31.940] (II) modeset(0): Output HDMI-1 has no monitor section
[    31.941] (II) modeset(0): EDID for output HDMI-1
[    31.941] (II) modeset(0): Manufacturer: DEL  Model: a0f9  Serial#: 1178867256
[    31.942] (II) modeset(0): Printing probed modes for output HDMI-1
[    31.942] (II) modeset(0): Modeline "1920x1080"x60.0  148.50 ...

# Read the raw EDID when the log is unhelpful
$ sudo find /sys/class/drm -name edid -exec sh -c 'echo "== $1"; wc -c < "$1"' _ {} \;
== /sys/class/drm/card0-eDP-1/edid
256
== /sys/class/drm/card0-HDMI-A-1/edid
0

# Zero bytes = no EDID (KVM, long cable, dead adapter). Force a mode:
$ xrandr --newmode "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync
$ xrandr --addmode HDMI-1 "1920x1080_60.00"
```

Forma permanente: una sección `Monitor` con `Option "CustomEDID" "HDMI-1:/etc/X11/edid.bin"` en el `Device`, o `Modeline` + `Modes` explícitos en `Screen`.

### 5.8 Fallas específicas de contenedores

| Síntoma | Causa | Solución |
|---|---|---|
| `Can't open display :99` desde el contenedor de la aplicación, Xvfb sano | `/tmp/.X11-unix` no compartido entre contenedores | `emptyDir` compartido montado en `/tmp/.X11-unix` en ambos |
| Las pestañas de Chromium se caen, `Failed to move to new namespace` / `SIGBUS` | `/dev/shm` está en el valor por defecto de 64 Mi | `emptyDir: {medium: Memory, sizeLimit: 2Gi}` en `/dev/shm` |
| `Xlib: extension "GLX" missing on display ":99"` | Xvfb arrancado sin `+extension GLX`, o sin Mesa en la imagen | Agregá el flag *y* `libgl1-mesa-dri`; definí `LIBGL_ALWAYS_SOFTWARE=1` |
| Las pruebas pasan localmente, capturas en blanco en CI | El servidor se reinició cuando salió el último cliente | `-noreset` |
| Las fuentes se renderizan como cuadraditos | No hay fuentes en la imagen | Instalá `fonts-dejavu-core` + `fontconfig`, ejecutá `fc-cache -f` |
| El servidor muere después del primer trabajo | Xvfb como PID 1 sin manejo de señales | Ejecutalo bajo un init (`tini`) o como sidecar con una sonda |

### 5.9 Lista de verificación — un cambio está terminado cuando todo esto pasa

```
$ grep -c '(EE)' ~/.local/share/xorg/Xorg.0.log          # → 0
0
$ xdpyinfo >/dev/null && echo "display OK"
display OK
$ xrandr --query | grep -c ' connected '                 # matches expected outputs
2
$ setxkbmap -query | grep -E 'layout|variant'            # matches policy
layout:     us,es
variant:    intl,
$ localectl status | grep -E 'VC Keymap|X11 Layout'      # console and X agree
       VC Keymap: us
     X11 Layout: us,es
$ xhost | head -1                                        # access control must be ENABLED
access control enabled, only authorized clients can connect
$ xset q | grep -A2 '^DPMS'                              # power policy as intended
  Standby: 0    Suspend: 0    Off: 0
  DPMS is Disabled
$ glxinfo -B | grep -E 'direct rendering|renderer'       # accel path as intended
direct rendering: Yes
OpenGL renderer string: Mesa Intel(R) UHD Graphics 620 (KBL GT2)
$ ss -ltn | grep -c ':6000'                              # → 0: no TCP listener
0
```

La última verificación es la que importa para la revisión de seguridad: **un servidor X escuchando en `6000/tcp` es un keylogger alcanzable por red** salvo que esté detrás de un firewall y protegido por cookie, y la cookie cruza el cable en texto plano de todos modos.

---

## 6. Alineación con el examen (LPIC-1 v5.0, objetivo 106.1)

| Área de conocimiento del objetivo | Dónde se cubre acá |
|---|---|
| Comprensión básica de la arquitectura de X11 | §2.1, §2.2 — cliente/servidor invertido, DIX/DDX, WM vs DE vs DM |
| Comprensión del archivo de configuración de X Window | §2.4, §3.1–§3.4 — tipos de sección, orden de búsqueda |
| Sobrescribir aspectos específicos de la configuración de Xorg (p. ej. distribución de teclado) | §3.1, §4.6 — `InputClass`, `localectl set-x11-keymap`, `setxkbmap` |
| Componentes de los entornos de escritorio (gestores de display, gestores de ventanas) | §2.1, §2.3, §4.1 |
| Conciencia de Wayland | §2.8 — modelo de compositor, XWayland, `XDG_SESSION_TYPE` |

**Términos y utilidades para tener en la punta de los dedos:** `/etc/X11/xorg.conf`, `/etc/X11/xorg.conf.d/`, `~/.xsession-errors`, `xhost`, `xauth`, `X`, `DISPLAY`.

---

## Referencias

**LPI — objetivos**
- LPIC-1 Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 objectives (acá vive el tema 106) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**X.Org Foundation — documentación upstream y páginas de manual**
- X.Org project — https://www.x.org/wiki/
- `Xorg(1)` — https://www.x.org/releases/current/doc/man/man1/Xorg.1.xhtml
- `xorg.conf(5)` — https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml
- `Xserver(1)` (opciones comunes del servidor, `-nolisten`, `-auth`) — https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml
- `xinit(1)` — https://www.x.org/releases/current/doc/man/man1/xinit.1.xhtml
- `startx(1)` — https://www.x.org/releases/current/doc/man/man1/startx.1.xhtml
- `xauth(1)` — https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml
- `xhost(1)` — https://www.x.org/releases/current/doc/man/man1/xhost.1.xhtml
- `Xsecurity(7)` (mecanismos de autorización) — https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml
- `Xvfb(1)` — https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml
- `Xephyr(1)` — https://www.x.org/releases/current/doc/man/man1/Xephyr.1.xhtml
- `xrandr(1)` — https://www.x.org/releases/current/doc/man/man1/xrandr.1.xhtml
- `xset(1)` — https://www.x.org/releases/current/doc/man/man1/xset.1.xhtml
- `xdpyinfo(1)` — https://www.x.org/releases/current/doc/man/man1/xdpyinfo.1.xhtml
- X Window System Protocol, version 11 — https://www.x.org/releases/current/doc/xproto/x11protocol.html
- Índice de páginas de manual de drivers de `xorg.conf.d` — https://www.x.org/releases/current/doc/man/

**freedesktop.org**
- Documentación del protocolo Wayland — https://wayland.freedesktop.org/docs/html/
- XWayland — https://wayland.freedesktop.org/xserver.html
- Documentación de libinput — https://wayland.freedesktop.org/libinput/doc/latest/
- XKeyboardConfig (`xkeyboard-config`) — https://www.freedesktop.org/wiki/Software/XKeyboardConfig/
- fontconfig — https://www.freedesktop.org/wiki/Software/fontconfig/
- `localectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/localectl.html
- `systemd-logind.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
- `loginctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- XDG Base Directory Specification — https://specifications.freedesktop.org/basedir-spec/latest/

**OpenSSH**
- `sshd_config(5)` — https://man.openbsd.org/sshd_config
- `ssh_config(5)` — https://man.openbsd.org/ssh_config
- `ssh(1)` — https://man.openbsd.org/ssh

**Stack gráfico**
- Documentación de DRM/KMS del kernel Linux — https://docs.kernel.org/gpu/drm-kms.html
- Documentación de Mesa 3D — https://docs.mesa3d.org/
- README del driver NVIDIA para Linux (headless, `AllowEmptyInitialConfiguration`) — https://download.nvidia.com/XFree86/Linux-x86_64/latest/README/

**Escritorios y gestores de display**
- GNOME Display Manager (GDM) — https://help.gnome.org/admin/gdm/stable/
- LightDM — https://github.com/canonical/lightdm
- SDDM — https://github.com/sddm/sddm

**Kubernetes**
- Volúmenes `emptyDir` (`/dev/shm` respaldado en memoria) — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Sondas de Pod — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
- Contexto de seguridad de Pod — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/