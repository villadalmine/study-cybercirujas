# 106.2 — Escritorios Gráficos

**LPIC-1 · Examen 102-500 · Tema 106 (Interfaces de Usuario y Escritorios)**
Alcance del objetivo: *conocimiento de los principales entornos de escritorio* y *conocimiento de los protocolos usados para acceder a sesiones de escritorio remoto*.
Términos y utilidades: `KDE`, `GNOME`, `Xfce`, `X11`, `XDMCP`, `VNC`, `Spice`, `RDP`.

Este es un objetivo de nivel introductorio en el examen, pero la superficie operativa que hay detrás — sesiones gráficas remotas en hosts bastión, estaciones de trabajo de ingeniería, consolas de hipervisor y escritorios containerizados — es donde a un equipo de plataforma efectivamente le suena el pager. El material siguiente trata el vocabulario del examen como punto de entrada y luego va a la profundidad que un Platform Architect necesita para diseñar, asegurar y depurar esa superficie.

---

## 1. Motivación: la sesión gráfica como carga de trabajo productiva

La mayoría de los ingenieros de infraestructura se encuentran con Linux gráfico solo dos veces: cuando se rompe el escritorio de una laptop, y cuando algo en la flota *necesita* píxeles. El segundo caso es el interesante, y es más común de lo que sugiere "corremos servidores headless":

| Motivador productivo | Qué se requiere realmente | Por qué no alcanza una TTY |
|---|---|---|
| **Break-glass de hipervisor** | Consola de un guest KVM cuyo stack de red o `sshd` está muerto | El guest no puede servir SSH; se necesita acceso al framebuffer fuera de banda antes de que el SO sea alcanzable |
| **Estaciones de trabajo de ingeniería / EDA / GIS** | Apps GUI aceleradas por GPU corriendo cerca de los datos, en una máquina del datacenter, mostradas remotamente | Los datasets son de cientos de GB; mover píxeles es más barato que mover datos |
| **Jump hosts regulados** | Un escritorio grabado, sin copiar-y-pegar, dentro de una zona segmentada | La sesión debe ser intermediada, auditada y descartable; una shell cruda evita el límite de DLP |
| **UIs de gestión de proveedores / appliances** | Un navegador dentro de la VLAN de gestión | La UI solo es alcanzable desde una dirección que nunca debe estar en una laptop |
| **Granjas de test de UI / end-to-end** | Servidor X efímero + navegador por cada job de CI | El test apunta al renderizado real, no a un DOM simulado |
| **Flotas de kiosco y cartelería digital** | Auto-login, una única app a pantalla completa, reinicio por watchdog, sin adornos de sesión | El "escritorio" *es* el producto; un compositor caído es una caída de servicio |

El problema arquitectónico en las seis filas es el mismo, y no es "qué escritorio es más lindo":

> **Una sesión gráfica es una carga de trabajo con estado, de larga vida y multiproceso, con una dependencia dura de un seat de dispositivos local, una cookie de autenticación, un bus IPC y un socket de servidor de display — y se te pide hacerla alcanzable a través de un límite de red sin convertirla en un camino de movimiento lateral.**

Descomponé eso en las cuatro decisiones a las que este objetivo realmente mapea:

1. **Qué protocolo de servidor de display** habla la sesión — X11 o Wayland. Esto decide si "remoto" es una característica del protocolo o un agregado.
2. **Qué entorno de escritorio** provee el compositor, el gestor de sesión y el demonio de configuración — esto decide la superficie de dependencias, el piso de memoria y si hay un servidor remoto incorporado.
3. **Qué protocolo de acceso remoto** transporta la sesión — reenvío X11, XDMCP, VNC, RDP o SPICE. Esto decide el comportamiento ante latencia, la persistencia de sesión, la redirección de dispositivos y los defaults de cifrado.
4. **Qué límite de confianza** termina el transporte — túnel SSH, TLS con un certificado real, ingress con mTLS, o (la respuesta incorrecta) un puerto en texto plano en `0.0.0.0`.

### 1.1 Anatomía de una sesión gráfica (el mapa de capas contra el que depurás)

```
                    ┌───────────────────────────────────────────────┐
  seat0             │  logind (systemd-logind)                      │
  ├─ /dev/dri/card0 │   • allocates SESSION id, seat, VT            │
  ├─ /dev/input/*   │   • grants device access via /dev/dri + udev  │
  └─ VT tty1..N     │   • sets XDG_SESSION_TYPE / XDG_SESSION_CLASS │
                    └───────────────┬───────────────────────────────┘
                                    │ PAM (pam_systemd, pam_keyinit)
                    ┌───────────────▼───────────────┐
                    │ Display Manager               │  gdm / sddm / lightdm / xdm
                    │  greeter session (class=greeter)│  ← XDMCP lives here
                    └───────────────┬───────────────┘
                                    │ exec session script (/etc/X11/Xsession,
                                    │  ~/.xsession, or systemd --user target)
        ┌───────────────────────────▼──────────────────────────────┐
        │ Session bus (D-Bus)  +  systemd --user  +  XDG portals     │
        └───────────────────────────┬──────────────────────────────┘
                                    │
        ┌───────────────────────────▼──────────────────────────────┐
        │ Compositor / Window Manager                               │
        │   GNOME → mutter    KDE → kwin_x11|kwin_wayland           │
        │   Xfce  → xfwm4     minimal → i3/sway/openbox             │
        └───────────────────────────┬──────────────────────────────┘
                                    │  X11: unix:/tmp/.X11-unix/X0
                                    │  Wayland: $XDG_RUNTIME_DIR/wayland-0
        ┌───────────────────────────▼──────────────────────────────┐
        │ Toolkit clients (GTK, Qt) + XWayland for legacy X clients │
        └───────────────────────────────────────────────────────────┘
```

Cada falla de la sección 7 es una ruptura en exactamente una de esas flechas.

### 1.2 X11 vs Wayland — la decisión que condiciona todas las posteriores

| Propiedad | X11 (Xorg) | Wayland |
|---|---|---|
| Transparencia de red | **Incorporada en el protocolo** — un cliente puede conectarse a un display remoto sobre TCP | **Ninguna** — el protocolo es solo un socket Unix local |
| Estrategia de acceso remoto | `ssh -X`, XDMCP, o capturar el framebuffer (`x11vnc`) | El compositor debe *implementar* un servidor (`gnome-remote-desktop`, `krdp`, `wayvnc`) o exportar vía portal de PipeWire |
| Captura de entrada/pantalla por cualquier cliente | Sí — cualquier cliente puede leer toda la pantalla y todas las pulsaciones de teclas | No — mediado por `xdg-desktop-portal` con consentimiento del usuario |
| Soporte de aplicaciones legadas | Nativo | Vía **XWayland** (un servidor X que renderiza en una superficie Wayland) |
| Escalado por monitor / HDR | Pobre (en la práctica, un único DPI global) | Nativo |
| Arranque rootless / sin privilegios | `Xorg` tradicionalmente necesitaba root o setuid (`Xwrapper.config`) | El compositor corre sin privilegios, obtiene DRM/entrada vía logind |
| Default en las distros actuales | Sesión legada / de respaldo | Default para GNOME y KDE Plasma 6 |

**Consecuencia operativa:** `ssh -X` y `x11vnc` dejan de funcionar silenciosamente el día que la flota pasa a Wayland por defecto. Un diseño de escritorio remoto escrito contra semántica X11 es un pasivo de migración; verificá `XDG_SESSION_TYPE` antes de prometer nada.

```console
$ echo "$XDG_SESSION_TYPE"
wayland
$ loginctl show-session "$XDG_SESSION_ID" -p Type -p Class -p Active -p Remote
Type=wayland
Class=user
Active=yes
Remote=no
```

---

## 2. Entornos de escritorio: comparación técnica

Un "entorno de escritorio" es un paquete de cinco componentes reemplazables. Conocer la descomposición es lo que te permite construir una imagen de kiosco de 180 MB en lugar de distribuir una de 2 GB.

| Componente | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| Toolkit | GTK 4 (+GTK 3 legado) | Qt 6 (Plasma 6) | GTK 3 (migración a GTK 4 en curso) |
| Compositor / WM | `mutter` (X11 + Wayland en un solo binario) | `kwin_x11` / `kwin_wayland` | `xfwm4` (X11); vista previa de Wayland vía `labwc`/`wayfire` en 4.20 |
| Shell / panel | `gnome-shell` (JavaScript sobre mutter) | `plasmashell` (QML) | `xfce4-panel`, `xfdesktop` |
| Gestor de sesión | `gnome-session` → unidades `systemd --user` | `startplasma-x11` / `startplasma-wayland`, `ksmserver` | `xfce4-session` |
| Almacén de configuración | `dconf` / GSettings (BD binaria, CLI `gsettings`) | Archivos INI de `KConfig` bajo `~/.config/*rc` (`kwriteconfig6`) | `xfconf` (XML bajo `~/.config/xfce4/xfconf/`) |
| Display manager por defecto | `gdm` | `sddm` | `lightdm` |
| Servidor remoto incorporado | `gnome-remote-desktop` (**RDP**, incl. headless) | `krdp` (**RDP**, Plasma 6) | ninguno — combinar con TigerVNC o xrdp |

### 2.1 Matriz de compromisos para decisiones de flota

| Dimensión | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| RSS en reposo, sesión nueva (orden de magnitud) | ~1.1–1.5 GB | ~0.9–1.3 GB | ~350–550 MB |
| Cierre de paquetes (metapaquete típico de distro) | El más grande | Grande | Chico |
| Madurez de Wayland | La más alta (implementación de referencia) | Alta (Plasma 6 usa Wayland por defecto) | Experimental |
| Historia de política / bloqueo | **La más fuerte** — BD dconf de sistema con `/etc/dconf/db/*.d/locks/`, claves obligatorias | Framework kiosk (`kiosk` `[KDE Action Restrictions]` en `kdeglobals`) | La más débil — xfconf por usuario, sin concepto de bloqueo obligatorio |
| Riesgo de extensibilidad | Las extensiones de GNOME Shell se rompen en cada release; una extensión mala mata la shell | Los plasmoides QML están aislados del compositor | Los plugins de panel son en C, estables entre releases |
| Encaje: escritorio corporativo gestionado | ✅ bloqueos dconf + política GDM + RDP incorporado | ⚠ viable, más superficie para bloquear | ❌ sin capa de política obligatoria |
| Encaje: escritorio containerizado / VDI | ❌ necesita `systemd --user`, logind, D-Bus — incómodo en un contenedor | ⚠ pesado, pero funciona | ✅ **el mejor encaje** — arranca desde un simple script `xstartup`, sin necesidad de logind |
| Encaje: kiosco / cartelería | ⚠ pesado; usar `gnome-kiosk` | ⚠ pesado | ✅ o directamente abandonar el DE por un WM pelado |
| Encaje: estación de trabajo con GPU (remota) | ✅ RDP + H.264 vía `gnome-remote-desktop` | ✅ RDP vía `krdp` | ⚠ solo VNC → sin codificación de video por hardware |

**Regla del arquitecto:** la elección de DE la manda la *política* y la *disponibilidad de servidor remoto*, no la estética. GNOME gana donde hay que imponer configuración; Xfce gana donde la sesión debe arrancar desde un script de shell dentro de un contenedor sin seat y sin logind.

### 2.2 Inspeccionar qué está corriendo realmente

```console
$ echo "$XDG_CURRENT_DESKTOP  $DESKTOP_SESSION"
GNOME  gnome

$ ps -eo comm,rss --sort=-rss | head -n 8
COMM              RSS
gnome-shell    412336
firefox        298104
gnome-softwar   96420
mutter-x11-fr   61208
gsd-color       38112
tracker-miner   35880
gnome-session-  22964
systemd          14204

$ systemctl --user list-units --type=target --state=active
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  basic.target                loaded active active Basic System
  default.target              loaded active active Main User Target
  gnome-session-initialized.t loaded active active GNOME Session is initialized
  gnome-session-wayland.targe loaded active active GNOME Wayland Session
  graphical-session.target    loaded active active Current graphical user session
  sockets.target              loaded active active Sockets

$ systemctl get-default
graphical.target
```

Cambiar el target de arranque — la solución más común al "el servidor rebooteó a una GUI y se quedó sin memoria":

```console
# systemctl set-default multi-user.target
Removed "/etc/systemd/system/default.target".
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target.
# systemctl isolate multi-user.target
```

Listar las definiciones de sesión instaladas (lo que un display manager ofrece en su menú):

```console
$ ls /usr/share/xsessions/ /usr/share/wayland-sessions/
/usr/share/wayland-sessions/:
gnome.desktop  plasma.desktop

/usr/share/xsessions/:
gnome-xorg.desktop  plasmax11.desktop  xfce.desktop

$ grep -E '^(Name|Exec|DesktopNames)=' /usr/share/xsessions/xfce.desktop
Name=Xfce Session
Exec=startxfce4
DesktopNames=XFCE
```

---

## 3. Protocolos de escritorio remoto: mecánica y compromisos

### 3.1 Reenvío X11 (el camino nativo del protocolo)

X11 es un **protocolo cliente/servidor donde el servidor es dueño del display y el cliente es la aplicación** — la nomenclatura está invertida respecto de todos los demás protocolos de esta lista. Como es transparente a la red, una aplicación en el host B puede renderizar en el servidor X del host A. El transporte TCP crudo escucha en el **puerto 6000 + número de display**, pero todo Xorg moderno arranca con `-nolisten tcp`, así que el transporte práctico es un canal SSH.

La autorización es un secreto compartido por display, **MIT-MAGIC-COOKIE-1**, almacenado en `~/.Xauthority` (o `$XAUTHORITY`).

```console
$ ss -lntp | grep -E ':600[0-9]'      # nothing: -nolisten tcp is the default
$ xauth list
workstation/unix:0  MIT-MAGIC-COOKIE-1  3a9f1e4c2b7d8e6f0a1b2c3d4e5f6a7b

$ ssh -X build-node-07
Last login: Tue Aug 25 09:14:02 2026 from 10.42.7.11
$ echo "$DISPLAY"
localhost:10.0
$ xauth list
build-node-07/unix:10  MIT-MAGIC-COOKIE-1  1f0c4e5a9b8d7c6e5f4a3b2c1d0e9f8a
$ xlsclients
build-node-07  xterm
$ xdpyinfo | sed -n '1,6p'
name of display:    localhost:10.0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12101014
X.Org version: 21.1.14
maximum request size:  16777212 bytes
```

`-X` vs `-Y` es una decisión de seguridad, no un interruptor de compatibilidad:

| Flag | Extensión de seguridad de X | Consecuencia |
|---|---|---|
| `ssh -X` | **No confiable** — el cliente queda restringido, se deniegan capturas de pantalla/registro de teclas de otras ventanas, la conexión expira tras `ForwardX11Timeout` (20 min por defecto) | Algunas apps fallan con `BadAccess`; seguro frente a un host remoto hostil |
| `ssh -Y` | **Confiable** — acceso total a tu display local | Un host remoto comprometido puede leer toda tu pantalla y cada pulsación de tecla. Nunca hacia un host no confiable. |
| `xhost +` | Deshabilita la autorización por completo | Cualquier host de la red puede abrir ventanas y capturar la entrada. Tratalo como un hallazgo P1. |

**Modelo de latencia:** X11 es petición/respuesta con muchos viajes de ida y vuelta por operación de UI. Sobre un enlace de 100 ms de RTT una app GTK/Qt moderna es inusable; sobre una LAN de <5 ms es excelente, y es la única opción que da verdadero remoteo de una sola ventana (sin costuras) sin todo un escritorio.

### 3.2 XDMCP — *login* remoto, no *escritorio* remoto

**X Display Manager Control Protocol**, **puerto UDP 177**. Invierte la dirección habitual: un servidor X local le pide a un display manager remoto un greeter de login, y toda la sesión corre luego en el host remoto, dibujando en el servidor X local sobre el protocolo de cable de X.

Hechos cardinales: **XDMCP no está cifrado, no está autenticado a nivel de transporte, y es solo X11** — no puede servir una sesión Wayland. Es un protocolo legado de cliente ligero. Habilitalo solo dentro de una VLAN de gestión aislada, o mejor, no lo habilites.

```ini
# /etc/gdm/custom.conf — GDM as an XDMCP server
[daemon]
WaylandEnable=false          # mandatory: XDMCP requires an Xorg session

[security]
DisallowTCP=false

[xdmcp]
Enable=true
Port=177
MaxSessions=8
MaxPending=4
DisplaysPerHost=2
```

```ini
# /etc/lightdm/lightdm.conf — LightDM equivalent
[XDMCPServer]
enabled=true
port=177
```

Lado cliente:

```console
$ Xephyr -query dm.mgmt.internal -screen 1280x800 :3 &
$ X -broadcast :2                       # discover any DM on the local segment
$ X -indirect chooser.mgmt.internal :2  # ask a chooser host for a host list
```

```console
# ss -lnup | grep :177
udp   UNCONN 0  0     0.0.0.0:177    0.0.0.0:*    users:(("gdm",pid=1188,fd=9))
```

### 3.3 VNC — RFB, el mínimo común denominador del framebuffer

**Protocolo Remote Framebuffer.** Escucha en **TCP 5900 + número de display** (`:1` → 5901). Envía rectángulos de píxeles más eventos de entrada; no sabe nada de ventanas, así que es universal, simple y comparativamente hambriento de ancho de banda.

Dos modos de despliegue, y confundirlos es la caída clásica:

| Modo | Servidor | Semántica |
|---|---|---|
| **Escritorio virtual** | `Xvnc` (TigerVNC), arrancado por `vncserver` | Crea un servidor X **nuevo y headless**. La consola física queda intacta. La sesión sobrevive a la desconexión del cliente. Este es el modo VDI. |
| **Captura de pantalla** | `x11vnc`, `wayvnc` | Se adjunta a un display **existente** (`:0`) y lo replica. Este es el modo de soporte remoto. `x11vnc` no puede capturar una sesión Wayland; `wayvnc` funciona solo con compositores wlroots. |

Tipos de seguridad (RFB 3.8): `None`, `VncAuth` (desafío/respuesta sobre una **contraseña truncada a 8 caracteres** — débil, nunca debe exponerse), `TLSVnc`/`TLSPlain` y `X509Vnc` (VeNCrypt). **El default seguro es `-localhost` más un túnel SSH o un proxy inverso que termine TLS.**

```ini
# /etc/tigervnc/vncserver.users  — maps display numbers to accounts
:1=sre-ops
:2=eda-tools
```

```ini
# ~/.vnc/config  — per-user session parameters
session=xfce
geometry=1920x1080
depth=24
localhost
alwaysshared
SecurityTypes=VncAuth
```

```console
$ vncpasswd
Password:
Verify:
Would you like to enter a view-only password (y/n)? n
$ ls -l ~/.vnc/passwd
-rw------- 1 sre-ops sre-ops 8 Aug 25 10:02 /home/sre-ops/.vnc/passwd

# systemctl enable --now vncserver@:1.service
Created symlink /etc/systemd/system/multi-user.target.wants/vncserver@:1.service → /usr/lib/systemd/system/vncserver@.service.

# systemctl status vncserver@:1.service --no-pager
● vncserver@:1.service - Remote desktop service (VNC)
     Loaded: loaded (/usr/lib/systemd/system/vncserver@.service; enabled)
     Active: active (running) since Tue 2026-08-25 10:03:11 -03; 12s ago
   Main PID: 4198 (vncsession)
      Tasks: 78 (limit: 18936)
     Memory: 412.7M
        CPU: 6.114s
     CGroup: /system.slice/system-vncserver.slice/vncserver@:1.service
             ├─4198 /usr/sbin/vncsession sre-ops :1
             ├─4211 /usr/bin/Xvnc :1 -auth /home/sre-ops/.Xauthority -desktop ...
             ├─4260 xfce4-session
             └─4288 xfwm4

$ ss -lntp | grep 590
tcp   LISTEN 0  5   127.0.0.1:5901   0.0.0.0:*   users:(("Xvnc",pid=4211,fd=8))
```

Conectar sobre un túnel SSH — la única exposición aceptable para `VncAuth`:

```console
$ ssh -N -L 5901:127.0.0.1:5901 sre-ops@vdi-01.mgmt.internal &
$ vncviewer 127.0.0.1:5901
TigerVNC Viewer 64-bit v1.14.1
Built on: 2026-03-04 09:11
Tue Aug 25 10:05:44 2026
 DecodeManager: Detected 8 CPU core(s)
 CConn:         Connected to host 127.0.0.1 port 5901
 CConnection:   Server supports RFB protocol version 3.8
 CConnection:   Using RFB protocol version 3.8
 CConnection:   Choosing security type VncAuth(2)
 CConn:         Using pixel format depth 24 (32bpp) little-endian rgb888
 CConn:         Enabling continuous updates
```

### 3.4 RDP — el que tiene redirección de dispositivos de verdad

**Remote Desktop Protocol**, **TCP 3389** (UDP 3389 para el transporte opcional de baja latencia). A diferencia de RFB es un protocolo de **canales virtuales** multiplexados: display, entrada, portapapeles, audio de entrada/salida, redirección de unidades, impresoras, tarjetas inteligentes y USB viajan cada uno por un canal separado. Negocia TLS (y opcionalmente NLA/CredSSP para pre-autenticación) como parte del handshake, y soporta códecs H.264/AVC444 acelerados por hardware.

Implementaciones de servidor en Linux:

| Servidor | Backend | Notas |
|---|---|---|
| **xrdp** + `xorgxrdp` | Xorg dedicado con el driver de video xrdp | Persistencia de sesión, redimensionado al reconectar, funciona con cualquier DE |
| **xrdp** + `Xvnc` | Front-end xrdp hacia un backend TigerVNC | Más simple, pierde las características de xorgxrdp |
| **gnome-remote-desktop** | Wayland/PipeWire, nativo de GNOME | Modos "screen share" y **headless**; CLI `grdctl` |
| **krdp** | Nativo de Plasma 6 | Se configura desde Preferencias del Sistema → Escritorio Remoto |

```ini
# /etc/xrdp/xrdp.ini  (excerpt — transport and security)
[Globals]
port=3389
use_vsock=false
security_layer=negotiate
crypt_level=high
certificate=/etc/xrdp/cert.pem
key_file=/etc/xrdp/key.pem
ssl_protocols=TLSv1.2, TLSv1.3
tls_ciphers=HIGH:!aNULL:!MD5
max_bpp=32
new_cursors=true
allow_channels=true
allow_multimon=true
bitmap_compression=true
bulk_compression=true

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20
```

```ini
# /etc/xrdp/sesman.ini  (excerpt — session lifecycle)
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=true
UserWindowManager=startwm.sh
DefaultWindowManager=startwm.sh

[Security]
AllowRootLogin=false
MaxLoginRetry=3
TerminalServerUsers=tsusers
TerminalServerAdmins=tsadmins
AlwaysGroupCheck=true
RestrictOutboundClipboard=all

[Sessions]
X11DisplayOffset=10
MaxSessions=50
KillDisconnected=false
DisconnectedTimeLimit=3600
IdleTimeLimit=7200
```

`xorgxrdp` necesita que un Xorg sin privilegios sea arrancable por un usuario que no está en la consola:

```ini
# /etc/X11/Xwrapper.config
allowed_users=anybody
needs_root_rights=yes
```

Lado cliente (FreeRDP 3):

```console
$ xfreerdp3 /v:vdi-01.mgmt.internal /u:sre-ops /d: \
    /size:1920x1080 /dynamic-resolution /gfx:AVC444 \
    +clipboard /sound:sys:pulse /drive:transfer,/home/dalmine/xfer \
    /cert:tofu
[10:22:04:118] [21874:00005572] [INFO][com.freerdp.core] - freerdp_connect:freerdp_set_last_error_ex resetting error state
[10:22:04:341] [21874:00005572] [INFO][com.freerdp.crypto] - creating certificate store at /home/dalmine/.config/freerdp/certs
[10:22:04:512] [21874:00005572] [INFO][com.freerdp.core] - ARM/AVC444 gfx pipeline negotiated
[10:22:05:007] [21874:00005572] [INFO][com.freerdp.client.common.cmdline] - Connected to vdi-01.mgmt.internal:3389
```

RDP headless de GNOME (nativo de Wayland, sin X11 en ningún punto del camino):

```console
$ grdctl rdp set-tls-cert ~/.local/share/gnome-remote-desktop/rdp-tls.crt
$ grdctl rdp set-tls-key  ~/.local/share/gnome-remote-desktop/rdp-tls.key
$ grdctl rdp set-credentials sre-ops
Password:
$ grdctl rdp enable
$ systemctl --user enable --now gnome-remote-desktop.service
$ grdctl status
RDP:
	Status: enabled
	TLS certificate: /home/sre-ops/.local/share/gnome-remote-desktop/rdp-tls.crt
	TLS key: /home/sre-ops/.local/share/gnome-remote-desktop/rdp-tls.key
	View-only: no
	Username: sre-ops
	Password: ●●●●●●●●
```

### 3.5 SPICE — el protocolo de consola del hipervisor

**Simple Protocol for Independent Computing Environments**, desarrollado para QEMU/KVM. Estructuralmente distinto de los demás: **SPICE lo implementa el hipervisor, no algo dentro del guest.** El servidor es `spice-server` enlazado dentro del proceso QEMU; por lo tanto funciona antes de que el kernel del guest arranque, a través de un kernel panic del guest, y entre reinicios del guest. TCP **5900+** por defecto (libvirt lo asigna con `autoport`), más un puerto TLS opcional.

Un agente opcional dentro del guest (`spice-vdagent` + `spice-vdagentd`, sobre un canal `virtio-serial` llamado `com.redhat.spice.0`) agrega la capa de comodidad: portapapeles compartido, resolución automática del guest ajustada a la ventana del cliente, mouse sin costuras (sin captura del puntero) y arrastrar-y-soltar de archivos. Sin el agente SPICE igual funciona — solo que tenés el puntero capturado y una resolución fija.

Capacidades distintivas: multi-monitor desde una sola conexión, **redirección de dispositivos USB** del cliente al guest, detección de flujo de video con compresión MJPEG/H.264, y audio vía los canales `playback`/`record`.

```console
$ virsh list --all
 Id   Name        State
---------------------------
 3    ci-runner   running
 -    win-golden  shut off

$ virsh domdisplay ci-runner
spice://127.0.0.1:5901

$ virsh dumpxml ci-runner | sed -n '/<graphics/,/<\/graphics>/p'
    <graphics type='spice' port='5901' tlsPort='5902' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
      <image compression='auto_glz'/>
      <streaming mode='filter'/>
      <clipboard copypaste='yes'/>
      <mouse mode='client'/>
    </graphics>

$ remote-viewer --spice-debug spice://127.0.0.1:5901
(remote-viewer:9214): GSpice-DEBUG: channel-main.c:1234 main-1:0: agent connected
(remote-viewer:9214): GSpice-DEBUG: channel-display.c:2011 display-2:0: display channel ready
```

Lado guest:

```console
$ systemctl status spice-vdagentd --no-pager
● spice-vdagentd.service - Agent daemon for Spice guests
     Loaded: loaded (/usr/lib/systemd/system/spice-vdagentd.service; enabled)
     Active: active (running) since Tue 2026-08-25 09:58:44 -03; 31min ago
   Main PID: 771 (spice-vdagentd)
$ ls -l /dev/virtio-ports/
lrwxrwxrwx 1 root root 11 Aug 25 09:58 com.redhat.spice.0 -> ../vport1p1
```

### 3.6 Matriz consolidada de compromisos entre protocolos

| | **Reenvío X11** | **XDMCP** | **VNC (RFB)** | **RDP** | **SPICE** |
|---|---|---|---|---|---|
| Puerto por defecto | 6000+N TCP (sobre canal SSH) | **177/UDP** | **5900+N TCP** | **3389 TCP/UDP** | 5900+ TCP (asignado por libvirt) |
| Unidad de transferencia | Primitivas de dibujo | Login + primitivas de dibujo | Rectángulos de framebuffer | Canales virtuales multiplexados | Canales + flujo de video del guest |
| Remotea una *sola ventana* | ✅ **el único que lo hace** | ❌ | ❌ | ❌ (RemoteApp es solo de Windows) | ❌ |
| Cifrado por defecto | ✅ (hereda el de SSH) | ❌ **ninguno** | ❌ (solo VncAuth; TLS vía VeNCrypt) | ✅ TLS negociado | ⚠ puerto TLS opcional |
| Fortaleza de autenticación | Claves SSH + cookie Xauth | PAM del DM, transporte en claro | Contraseña de **8 caracteres** (VncAuth) | PAM/NLA, credenciales de largo completo | Ticket / SASL / TLS |
| La sesión sobrevive a la desconexión | ❌ muere con el canal SSH | ❌ muere con el servidor X | ✅ (modo Xvnc) | ✅ (xrdp mantiene la sesión de sesman) | ✅ (atada a la VM, no al cliente) |
| Funciona antes de que arranque el SO del guest | ❌ | ❌ | ❌ | ❌ | ✅ **el único que lo hace** |
| Funciona en una sesión Wayland | ⚠ solo clientes X, vía XWayland | ❌ **solo X11** | ⚠ necesita `wayvnc`/portal | ✅ `gnome-remote-desktop`, `krdp` | ✅ (a nivel de hipervisor, agnóstico del guest) |
| Portapapeles | ✅ (selecciones de X) | ✅ | ⚠ solo texto, a menudo inestable | ✅ texto + archivos | ✅ con `spice-vdagent` |
| Redirección de audio | ❌ | ❌ | ❌ | ✅ | ✅ |
| Redirección de USB / unidades | ❌ | ❌ | ❌ | ✅ unidades, impresoras, tarjetas inteligentes | ✅ **passthrough de USB** |
| Multi-monitor | ✅ (monitores del servidor X local) | ✅ | ⚠ un solo framebuffer | ✅ | ✅ |
| Codificación de video por hardware | ❌ | ❌ | ❌ | ✅ H.264/AVC444 | ✅ H.264/MJPEG |
| Tolerancia a 100 ms de RTT | ❌ **la peor** (viajes de ida y vuelta muy parlanchines) | ❌ | ⚠ aceptable | ✅ **la mejor** | ✅ |
| Ancho de banda, escritorio en reposo | muy bajo | muy bajo | bajo–moderado | bajo | bajo |
| Ancho de banda, video a pantalla completa | ❌ inusable | ❌ inusable | alto (10–40 Mbps) | moderado (3–8 Mbps) | moderado (3–8 Mbps) |
| Uso productivo principal | Una sola herramienta GUI desde un host de build | Clientes ligeros legados (evitar) | VDI headless, granjas de test de CI | Escritorios gestionados, estaciones de trabajo con GPU | Consola KVM, break-glass |

---

## 4. Arquitecturas de referencia y manifiestos de infraestructura completos

### 4.1 VNC endurecido por usuario en un bastión (solo loopback + SSH)

```ini
# /etc/systemd/system/vncserver@.service.d/hardening.conf
# Drop-in over the distribution unit: bind loopback only, cap resources,
# and make the session die cleanly when the user's tunnel goes away.
[Service]
# Resource containment: a runaway browser must not take the bastion down.
MemoryMax=3G
MemoryHigh=2500M
CPUQuota=200%
TasksMax=512

# Filesystem and privilege containment.
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=strict
ReadWritePaths=/home /run /tmp/.X11-unix /var/log
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Never leave a zombie desktop burning RAM for a week.
RuntimeMaxSec=12h
Restart=on-failure
RestartSec=5s
```

```ini
# /etc/ssh/sshd_config.d/50-remote-desktop.conf
# The only path to 5901..5910 is an authenticated SSH tunnel.
X11Forwarding no
AllowTcpForwarding local
PermitOpen 127.0.0.1:5901 127.0.0.1:5902 127.0.0.1:5903
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 4
```

```console
# firewall-cmd --permanent --add-service=ssh
success
# firewall-cmd --permanent --remove-port=5901-5910/tcp
success
# firewall-cmd --reload
success
# firewall-cmd --list-all
public (active)
  target: default
  services: ssh
  ports:
  protocols:
```

### 4.2 Escritorio Xfce containerizado en Kubernetes (Xvnc + sidecar noVNC)

El patrón: `Xvnc` escucha en **127.0.0.1** dentro del pod; un sidecar `websockify` en el mismo namespace de red lo puentea a HTTP/WebSocket; el Ingress termina TLS e impone autenticación. Ninguna contraseña de VNC cruza jamás la red como control primario.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: remote-desktops
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: xfce-session
  namespace: remote-desktops
data:
  xstartup: |
    #!/bin/sh
    # TigerVNC executes this as the session leader for display :1.
    # A bare `startxfce4` inherits a stale session manager and yields the
    # classic grey screen; unset both handles before exec'ing the DE.
    unset SESSION_MANAGER
    unset DBUS_SESSION_BUS_ADDRESS
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=XFCE
    export XDG_RUNTIME_DIR=/tmp/runtime-student
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    exec dbus-launch --exit-with-session startxfce4
  vnc-config: |
    session=xfce
    geometry=1920x1080
    depth=24
    localhost
    alwaysshared
    SecurityTypes=None
    AcceptCutText=1
    SendCutText=1
    AcceptSetDesktopSize=1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-student
  namespace: remote-desktops
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xfce-desktop
  namespace: remote-desktops
  labels:
    app.kubernetes.io/name: xfce-desktop
    app.kubernetes.io/component: vdi
spec:
  replicas: 1
  strategy:
    type: Recreate          # a desktop session is stateful; never roll two at once
  selector:
    matchLabels:
      app.kubernetes.io/name: xfce-desktop
  template:
    metadata:
      labels:
        app.kubernetes.io/name: xfce-desktop
        app.kubernetes.io/component: vdi
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: seed-home
          image: registry.internal/vdi/xfce-vnc:1.14.1
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mkdir -p /home/student/.vnc
              install -m 0755 /config/xstartup   /home/student/.vnc/xstartup
              install -m 0644 /config/vnc-config /home/student/.vnc/config
              echo "seeded $(date -u +%FT%TZ)"
          volumeMounts:
            - name: home
              mountPath: /home/student
            - name: session-config
              mountPath: /config
              readOnly: true
      containers:
        - name: desktop
          image: registry.internal/vdi/xfce-vnc:1.14.1
          command:
            - /usr/bin/Xvnc
          args:
            - ":1"
            - "-geometry=1920x1080"
            - "-depth=24"
            - "-localhost=1"
            - "-SecurityTypes=None"
            - "-AlwaysShared=1"
            - "-AcceptSetDesktopSize=1"
            - "-desktop=xfce-vdi"
            - "-xstartup=/home/student/.vnc/xstartup"
          env:
            - name: HOME
              value: /home/student
            - name: USER
              value: student
            - name: XDG_RUNTIME_DIR
              value: /tmp/runtime-student
          ports:
            - name: rfb
              containerPort: 5901
              protocol: TCP
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
          startupProbe:
            tcpSocket:
              port: 5901
            periodSeconds: 5
            failureThreshold: 24
          livenessProbe:
            tcpSocket:
              port: 5901
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: home
              mountPath: /home/student
            - name: x11-socket
              mountPath: /tmp/.X11-unix
            - name: runtime
              mountPath: /tmp/runtime-student
            - name: dshm
              mountPath: /dev/shm
        - name: novnc
          image: registry.internal/vdi/novnc:1.5.0
          command:
            - /usr/bin/websockify
          args:
            - "--web=/usr/share/novnc"
            - "--heartbeat=30"
            - "0.0.0.0:6080"
            - "127.0.0.1:5901"       # same pod = same netns = loopback reachable
          ports:
            - name: http
              containerPort: 6080
              protocol: TCP
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /vnc.html
              port: 6080
            periodSeconds: 10
      volumes:
        - name: home
          persistentVolumeClaim:
            claimName: home-student
        - name: session-config
          configMap:
            name: xfce-session
            defaultMode: 0755
        - name: x11-socket
          emptyDir: {}
        - name: runtime
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi      # browsers crash with the 64 MB default /dev/shm
---
apiVersion: v1
kind: Service
metadata:
  name: xfce-desktop
  namespace: remote-desktops
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: xfce-desktop
  ports:
    - name: http
      port: 80
      targetPort: 6080
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: xfce-desktop
  namespace: remote-desktops
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: xfce-desktop
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 6080
          protocol: TCP
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - to:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - port: 443
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: xfce-desktop
  namespace: remote-desktops
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/auth-url: "https://auth.internal/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://auth.internal/oauth2/start?rd=$escaped_request_uri"
    cert-manager.io/cluster-issuer: internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["desktop.vdi.internal"]
      secretName: xfce-desktop-tls
  rules:
    - host: desktop.vdi.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: xfce-desktop
                port:
                  number: 80
```

```console
$ kubectl -n remote-desktops rollout status deploy/xfce-desktop
Waiting for deployment "xfce-desktop" rollout to finish: 0 of 1 updated replicas are available...
deployment "xfce-desktop" successfully rolled out

$ kubectl -n remote-desktops get pod -l app.kubernetes.io/name=xfce-desktop -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
xfce-desktop-6c9f7b4d8c-2vqkp   2/2     Running   0          71s   10.42.3.87   node-04

$ kubectl -n remote-desktops exec deploy/xfce-desktop -c desktop -- ss -lntp
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      5        127.0.0.1:5901        0.0.0.0:*     users:(("Xvnc",pid=1,fd=7))
LISTEN 0      5        0.0.0.0:6080          0.0.0.0:*     users:(("websockify",pid=1,fd=3))

$ kubectl -n remote-desktops exec deploy/xfce-desktop -c desktop -- xlsclients -display :1
xfce-desktop  xfce4-panel
xfce-desktop  xfdesktop
xfce-desktop  xfwm4
```

### 4.3 Consola SPICE para un guest KVM (fragmento de dominio libvirt)

```xml
<!-- virsh edit ci-runner : TLS-only SPICE, agent channel, USB redirection -->
<domain type='kvm'>
  <name>ci-runner</name>
  <memory unit='GiB'>8</memory>
  <vcpu placement='static'>4</vcpu>
  <devices>

    <graphics type='spice' autoport='yes' listen='127.0.0.1'
              defaultMode='secure' passwd='rotated-by-vault'
              passwdValidTo='2026-08-25T14:00:00'>
      <listen type='address' address='127.0.0.1'/>
      <channel name='main'    mode='secure'/>
      <channel name='display' mode='secure'/>
      <channel name='inputs'  mode='secure'/>
      <channel name='cursor'  mode='secure'/>
      <channel name='playback' mode='secure'/>
      <channel name='record'   mode='secure'/>
      <image compression='auto_glz'/>
      <jpeg compression='auto'/>
      <zlib compression='auto'/>
      <playback compression='on'/>
      <streaming mode='filter'/>
      <clipboard copypaste='no'/>       <!-- DLP: no exfiltration via clipboard -->
      <filetransfer enable='no'/>
      <mouse mode='client'/>
    </graphics>

    <video>
      <model type='virtio' heads='2' primary='yes'>
        <acceleration accel3d='no'/>
      </model>
    </video>

    <!-- guest agent channel: clipboard, resolution matching, seamless mouse -->
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>

    <!-- USB redirection: two slots over the SPICE channel -->
    <controller type='usb' index='0' model='qemu-xhci' ports='8'/>
    <redirdev bus='usb' type='spicevmc'/>
    <redirdev bus='usb' type='spicevmc'/>
    <redirfilter>
      <usbdev class='0x0b' allow='yes'/>   <!-- smartcard readers only -->
      <usbdev allow='no'/>
    </redirfilter>

  </devices>
</domain>
```

```console
# virsh define /etc/libvirt/qemu/ci-runner.xml
Domain 'ci-runner' defined from /etc/libvirt/qemu/ci-runner.xml
# virsh start ci-runner
Domain 'ci-runner' started
$ virsh domdisplay --type spice ci-runner
spice://127.0.0.1?tls-port=5902
$ ssh -N -L 5902:127.0.0.1:5902 kvm-host-02 &
$ remote-viewer "spice://127.0.0.1?tls-port=5902" \
    --spice-ca-file=/etc/pki/libvirt-spice/ca-cert.pem
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Secuencia de verificación de línea de base

```console
$ loginctl list-sessions
SESSION  UID USER    SEAT  LEADER CLASS   TTY  STATE  IDLE SINCE
      3 1000 sre-ops seat0   1854 user    tty2 active no   -
      7 1000 sre-ops -       4198 user    -    active no   -
     c1   42 gdm     seat0   1201 greeter tty1 active no   -

3 sessions listed.

$ loginctl show-session 7 -p Type -p Remote -p Service -p Scope
Type=x11
Remote=no
Service=vncsession
Scope=session-7.scope

$ loginctl seat-status seat0
seat0
	Sessions: *3 c1
	 Devices:
		 ├─/sys/devices/pci0000:00/0000:00:02.0/drm/card1
		 ├─/sys/devices/.../input/input4  (AT Translated Set 2 keyboard)
		 └─/sys/devices/.../input/input12 (SynPS/2 Synaptics TouchPad)

$ ss -lntup | grep -E ':(177|3389|5900|5901|6000|6080)\b'
udp  UNCONN 0 0    0.0.0.0:177   0.0.0.0:*  users:(("gdm",pid=1188,fd=9))
tcp  LISTEN 0 5  127.0.0.1:5901  0.0.0.0:*  users:(("Xvnc",pid=4211,fd=8))
tcp  LISTEN 0 2    0.0.0.0:3389  0.0.0.0:*  users:(("xrdp",pid=1180,fd=11))

$ xrandr --query
Screen 0: minimum 32 x 32, current 1920 x 1080, maximum 32768 x 32768
VNC-0 connected primary 1920x1080+0+0 0mm x 0mm
   1920x1080     60.00*+
   1280x800      60.00
   1024x768      60.00

$ glxinfo -B | grep -E 'renderer|OpenGL version'
OpenGL renderer string: llvmpipe (LLVM 19.1.0, 256 bits)
OpenGL version string: 4.5 (Compatibility Profile) Mesa 25.1.4
```

`llvmpipe` en una máquina con GPU es en sí mismo un hallazgo: el renderizado está en la CPU, así que el escritorio va a ser lento y la cuota de CPU se la va a comer el compositor.

### 5.2 Tabla de triage de fallas

| Síntoma | Causa más probable | Comando de confirmación | Solución |
|---|---|---|---|
| `Error: Can't open display:` (vacío) | `DISPLAY` sin definir | `echo "[$DISPLAY]"` | `export DISPLAY=:0` localmente, o reconectar con `ssh -X` |
| `X11 forwarding request failed on channel 0` | `X11Forwarding no` en el servidor, **o** el binario `xauth` no está instalado en el servidor | `sshd -T \| grep -i x11`; `command -v xauth` | Habilitar `X11Forwarding yes`, instalar `xorg-x11-xauth`, `systemctl reload sshd` |
| `ssh -X` funciona, `DISPLAY` definido, igual `Can't open display` | Cookie ausente/obsoleta en `~/.Xauthority`, o `$HOME` no escribible (disco lleno, root-squash de NFS) | `xauth list`; `touch ~/.Xauthority` | `rm ~/.Xauthority && exec ssh -X ...`; corregir cuota/permisos |
| El reenvío funciona con `xterm`, falla con una app GUI con `BadAccess` | Reenvío no confiable (`-X`) + extensión X SECURITY | correr bajo `ssh -Y` para confirmar | Preferir VNC/RDP; usar `-Y` solo hacia un host confiable |
| El reenvío X11 muere después de ~20 minutos | Expiración de `ForwardX11Timeout` en reenvío no confiable | `sshd -T \| grep -i forwardx11timeout` | Subir el timeout, o pasar a un protocolo persistente (VNC/RDP) |
| Sesión Wayland: `ssh -X` funciona solo con algunas apps | Apps GTK/Qt que prefieren el backend Wayland; solo los clientes XWayland se reenvían | `echo $WAYLAND_DISPLAY`; `wayland-info \| head` | `GDK_BACKEND=x11` / `QT_QPA_PLATFORM=xcb`, o usar RDP |
| **VNC: pantalla gris con un cursor X, sin panel** | `~/.vnc/xstartup` no ejecutable, o nunca hace `exec` de un WM | `ls -l ~/.vnc/xstartup`; `tail ~/.vnc/*.log` | `chmod +x`; terminar el script con `exec dbus-launch --exit-with-session startxfce4` |
| **VNC: pantalla negra, la sesión sale al instante** | El DE falta en la imagen, o D-Bus no arrancó | `grep -iE 'error\|fatal' ~/.vnc/host:1.log` | Instalar el metapaquete del DE; envolver con `dbus-launch` |
| `vncserver` sale: *A VNC server is already running as :1* | Lock/socket obsoleto de un kill sucio | `ls /tmp/.X11-unix /tmp/.X1-lock` | `vncserver -kill :1`; si persiste, borrar `/tmp/.X1-lock` y `/tmp/.X11-unix/X1` |
| VNC conecta desde localhost, timeout desde remoto | `-localhost` (correcto) o un descarte del firewall | `ss -lntp \| grep 5901`; `nc -zv host 5901` | Mantener `-localhost`; llegar vía `ssh -L`. Nunca exponer VncAuth a una red ruteada |
| **xrdp: pantalla azul de login, y desconexión instantánea** | Xorg no puede arrancar sin privilegios, o ya existe una sesión para ese usuario | `journalctl -u xrdp-sesman -n 50` | Poner `allowed_users=anybody` en `/etc/X11/Xwrapper.config`; reconectar a la sesión existente |
| xrdp: conecta pero el escritorio está vacío | `startwm.sh` no lanza un DE | `cat /etc/xrdp/startwm.sh`; `~/.xsession-errors` | Agregar `exec startxfce4` (o el lanzador del DE) a `startwm.sh` |
| xrdp: polkit pregunta en cada login ("Authentication required to create a color profile") | Las reglas de polkit deniegan acciones fuera de consola (`auth_admin`) | `pkaction --action-id org.freedesktop.color-manager.create-device` | Agregar una regla de polkit que permita esa acción al grupo de usuarios RDP |
| El cliente RDP aborta en la negociación TLS | `/etc/xrdp/cert.pem` vencido/autofirmado, o desajuste de protocolo | `openssl x509 -in /etc/xrdp/cert.pem -noout -dates` | Reemitir el certificado; alinear `ssl_protocols`; `/cert:tofu` en el cliente solo para laboratorio |
| **XDMCP: "XDMCP fatal error: Session declined"** | Se alcanzó `MaxSessions`/`DisplaysPerHost`, o el host no está en la ACL del DM | `journalctl -u gdm -n 100`; `/etc/X11/xdm/Xaccess` | Subir los límites; agregar el host a `Xaccess` |
| XDMCP: ninguna respuesta | UDP/177 filtrado, o el DM está corriendo Wayland | `ss -lnup \| grep :177`; `nc -zvu dm-host 177` | Abrir UDP/177 en la VLAN de gestión; poner `WaylandEnable=false` |
| **SPICE: sin portapapeles, puntero capturado, resolución fija** | `spice-vdagent` no está corriendo en el guest, o falta el canal virtio | `systemctl status spice-vdagentd`; `ls /dev/virtio-ports/` | Instalar `spice-vdagent`; agregar el canal `com.redhat.spice.0` al XML del dominio |
| SPICE: `Could not connect to 127.0.0.1:5900` | `listen='127.0.0.1'` (por diseño) y sin túnel; o `autoport` movió el puerto | `virsh domdisplay <vm>` | Usar el puerto que reporta `domdisplay`; tunelizar con `ssh -L` |
| El escritorio está lento, la CPU clavada por el compositor | Renderizado por software (`llvmpipe`) | `glxinfo -B \| grep renderer` | Instalar el driver de GPU; para VNC/xrdp aceptar el renderizado por CPU y reducir profundidad/geometría |
| Las pestañas del navegador se caen dentro del escritorio containerizado | `/dev/shm` de 64 MB por defecto | `df -h /dev/shm` | `emptyDir: {medium: Memory, sizeLimit: 1Gi}` montado en `/dev/shm` |
| El servidor arranca en una GUI y se queda sin memoria | `default.target` es `graphical.target` | `systemctl get-default` | `systemctl set-default multi-user.target` |

### 5.3 Ubicaciones de logs que responden la pregunta

```console
$ ls -l ~/.vnc/*.log
-rw-r--r-- 1 sre-ops sre-ops 4821 Aug 25 10:03 /home/sre-ops/.vnc/vdi-01:1.log

$ tail -n 6 ~/.vnc/vdi-01:1.log
Xvnc TigerVNC 1.14.1 - built Mar  4 2026 09:11:22
Copyright (C) 1999-2025 TigerVNC Team and many others (see README.rst)
 vncext:      VNC extension running!
 vncext:      Listening for VNC connections on local interface(s), port 5901
 vncext:      created VNC server for screen 0
/home/sre-ops/.vnc/xstartup: line 8: startxfce4: command not found   ← root cause

# journalctl -u xrdp-sesman -n 8 --no-pager
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [INFO ] Access permitted for user: sre-ops
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [INFO ] starting Xorg session...
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [ERROR] X server for display 10 startup timeout
Aug 25 10:41:02 vdi-01 xrdp-sesman[1183]: [ERROR] another Xserver might already be active on display 10

$ tail -n 3 ~/.xsession-errors
dbus-update-activation-environment: setting DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
xfce4-session: cannot open display
Xsession: unable to launch "startxfce4" X session

# journalctl -b -u gdm --no-pager | tail -n 4
Aug 25 09:57:41 vdi-01 gdm[1188]: Gdm: GdmDisplay: Session never registered, failing
Aug 25 09:57:41 vdi-01 gdm[1188]: Gdm: Failed to start Wayland display, falling back to X11

$ ls -l ~/.local/share/xorg/Xorg.0.log /var/log/Xorg.0.log 2>/dev/null
-rw-r--r-- 1 sre-ops sre-ops 42118 Aug 25 09:57 /home/sre-ops/.local/share/xorg/Xorg.0.log
```

Un Xorg rootless escribe en `~/.local/share/xorg/Xorg.N.log`; solo un servidor X arrancado por root escribe `/var/log/Xorg.N.log`. Mirar el archivo equivocado es la razón más común del "no hay logs".

### 5.4 Lista de verificación de seguridad

```console
$ xhost
access control enabled, only authorized clients can connect      # required state

$ sshd -T | grep -iE 'x11forwarding|x11uselocalhost|forwardx11timeout'
x11forwarding no
x11uselocalhost yes

$ ss -lntp | awk '$4 ~ /0\.0\.0\.0:(59[0-9][0-9]|177)/ {print "EXPOSED:", $4, $6}'
                                                     # empty output = pass

$ nmap -sV -p 177,3389,5900-5910,6000-6010 vdi-01.mgmt.internal
Starting Nmap 7.98 ( https://nmap.org ) at 2026-08-25 11:02 -03
Nmap scan report for vdi-01.mgmt.internal (10.42.7.31)
Host is up (0.00042s latency).
Not shown: 20 filtered tcp ports (no-response)
PORT     STATE SERVICE       VERSION
3389/tcp open  ms-wbt-server xrdp
```

| Control | Verificación | Esperado |
|---|---|---|
| Sin listener TCP de X11 | `ss -lntp \| grep :600` | vacío (`-nolisten tcp`) |
| Autorización de X activa | `xhost` | "access control enabled" |
| Sin VNC en texto plano sobre una IP ruteada | `ss -lntp \| grep 590` | ligado solo a `127.0.0.1` |
| XDMCP apagado salvo justificación | `ss -lnup \| grep :177` | vacío |
| RDP presenta un certificado gestionado | `openssl s_client -connect host:3389 -starttls rdp` | emitido por CA, no vencido |
| Redirección de portapapeles/unidades acotada | `grep -i clipboard /etc/xrdp/sesman.ini` | `RestrictOutboundClipboard=all` donde aplique DLP |
| TTL de sesión impuesto | `grep -i TimeLimit /etc/xrdp/sesman.ini` | `DisconnectedTimeLimit` / `IdleTimeLimit` definidos |

---

## 6. Datos críticos para el examen (memorizar)

| Dato | Valor |
|---|---|
| Puerto TCP de X11 para el display `:N` | **6000 + N** |
| Puerto y transporte de XDMCP | **177/UDP** |
| Puerto de VNC para el display `:N` | **5900 + N** (`:1` → 5901) |
| Puerto de RDP | **3389** (TCP, opcionalmente UDP) |
| Puerto de SPICE | 5900+ , asignado por libvirt (`autoport='yes'`) |
| Tipo/archivo de cookie de autorización de X11 | `MIT-MAGIC-COOKIE-1` en `~/.Xauthority` (`xauth`) |
| Reenvío X11 de SSH confiable vs no confiable | `ssh -Y` confiable, `ssh -X` no confiable |
| Compositor / DM / almacén de configuración de GNOME | `mutter` / `gdm` / `dconf` |
| Compositor / DM / almacén de configuración de KDE Plasma | `kwin` / `sddm` / archivos KConfig |
| WM / DM / almacén de configuración de Xfce | `xfwm4` / `lightdm` / `xfconf` |
| Protocolo sin ningún cifrado incorporado | **XDMCP** |
| Protocolo que funciona antes de que arranque el SO del guest | **SPICE** |
| Protocolo que puede remotear una sola ventana | **Reenvío X11** |
| Protocolos con redirección de USB/dispositivos | **RDP** (unidades, impresoras, tarjetas inteligentes) y **SPICE** (USB) |
| Agente guest de SPICE (portapapeles, resolución, mouse) | `spice-vdagent` / `spice-vdagentd` |
| Alternar arranque en modo texto vs gráfico | `systemctl set-default multi-user.target` / `graphical.target` |

---

## 7. Referencias

- LPI — Objetivos del examen LPIC-1 102-500 (Tema 106: Interfaces de Usuario y Escritorios): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — Objetivos del examen LPIC-1 101-500: https://www.lpi.org/our-certifications/exam-101-objectives/
- X.Org Foundation — Documentación del servidor Xorg: https://www.x.org/wiki/
- X.Org — Páginas de manual `Xserver(1)` y `Xsecurity(7)`: https://www.x.org/releases/current/doc/man/man1/Xserver.1.xhtml
- X.Org — Especificación del X Display Manager Control Protocol (XDMCP): https://www.x.org/releases/current/doc/xorgdocs/specs/XDMCP/xdmcp.html
- Wayland — Documentación del protocolo y la arquitectura: https://wayland.freedesktop.org/docs/html/
- freedesktop.org — XDG Desktop Portal (captura de pantalla / escritorio remoto en Wayland): https://flatpak.github.io/xdg-desktop-portal/docs/
- GNOME — Documentación del proyecto y guía de administración del sistema: https://help.gnome.org/admin/system-admin-guide/stable/
- GNOME — `gnome-remote-desktop` (servidor RDP, modo headless): https://gitlab.gnome.org/GNOME/gnome-remote-desktop
- KDE — Documentación del escritorio Plasma: https://docs.kde.org/
- KDE — KRdp (servidor RDP de Plasma): https://invent.kde.org/plasma/krdp
- Xfce — Documentación oficial: https://docs.xfce.org/
- TigerVNC — Documentación del proyecto y páginas de manual de `vncserver`/`Xvnc`: https://tigervnc.org/
- Especificación del protocolo RFB (mantenida por la comunidad): https://github.com/rfbproto/rfbproto
- xrdp — Documentación oficial y referencia de configuración: https://github.com/neutrinolabs/xrdp/wiki
- FreeRDP — Documentación de cliente y servidor: https://www.freerdp.com/
- Microsoft — `[MS-RDPBCGR]` Conectividad básica y remoteo de gráficos del Remote Desktop Protocol: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/
- SPICE — Protocolo y manual de usuario: https://www.spice-space.org/documentation.html
- libvirt — Referencia del elemento `<graphics>` del XML de dominio: https://libvirt.org/formatdomain.html#graphical-framebuffers
- systemd — `systemd-logind(8)` y `loginctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
- OpenSSH — Opciones de reenvío X11 de `ssh_config(5)` / `sshd_config(5)`: https://man.openbsd.org/sshd_config
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- noVNC / websockify — Documentación del proyecto: https://novnc.com/info.html