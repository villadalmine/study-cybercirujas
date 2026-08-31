# LPIC-1 — Tema 106.2: Escritorios gráficos
## Ejercicios guiados

**Examen:** 101-500 / 102-500 (v5.0) · **Objetivo 106.2** · **Peso:** 0.0
**Alcance del objetivo:** conocimiento de los principales entornos de escritorio (KDE, GNOME, Xfce) y comprensión de los protocolos usados para alcanzar una sesión gráfica remota (X11, XDMCP, VNC, Spice, RDP).

### Prerrequisitos del laboratorio

| Elemento | Requisito |
|---|---|
| Máquinas | Dos hosts Linux en el mismo segmento L2. `station` (tu estación de trabajo, con una sesión gráfica en ejecución) y `srv` (el host remoto). Un par de VMs sirve. |
| Privilegios | `sudo` en ambos. |
| Paquetes que vas a instalar | `xfce4`, `x11-utils`/`xorg-x11-utils`, `wmctrl`, `tigervnc-standalone-server`, `x11vnc`, `xrdp`, `freerdp2-x11`/`freerdp`, `virt-viewer`, `xserver-xephyr`/`xorg-x11-server-Xephyr` |
| Firewall | Tenés que poder abrir/cerrar TCP 3389, 5900–5910 y UDP 177 en `srv`. |

La salida de los comandos que se muestra en este documento es **representativa** — las cadenas de versión, PIDs, cookies y nombres de interfaz van a diferir en tu sistema. Lo que sí debe coincidir es la *forma* de la salida; donde no coincida, esa es la señal diagnóstica.

A lo largo del documento, `station$` y `srv$` marcan en qué host se ejecuta el comando.

---

## Bloque 1 — Identificar la sesión: servidor gráfico, tipo de sesión, entorno de escritorio

Una cantidad enorme de la resolución de problemas de 106.2 se reduce a responder correctamente tres preguntas antes de tocar nada: *qué servidor gráfico está corriendo*, *qué tipo de sesión inició el gestor de inicio de sesión* y *qué entorno de escritorio se apoya encima*. Son tres hechos independientes, y la gente los confunde habitualmente.

1. Desde una terminal **dentro de tu sesión gráfica**, preguntale a logind qué cree que es la sesión:

```bash
station$ loginctl show-session auto -p Id -p Type -p Class -p Remote -p Display -p Active
```

```
Id=2
Type=wayland
Class=user
Remote=no
Display=
Active=yes
```

`Type=` es la respuesta autoritativa: `x11`, `wayland` o `tty`. (`Display=` acá es el campo de contabilidad interna de logind, no `$DISPLAY`; frecuentemente está vacío.)

2. Ahora preguntale al entorno de la propia sesión:

```bash
station$ echo "type=$XDG_SESSION_TYPE  desktop=$XDG_CURRENT_DESKTOP  session=$DESKTOP_SESSION"
station$ echo "DISPLAY=$DISPLAY  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
```

```
type=wayland  desktop=GNOME  session=gnome
DISPLAY=:0  WAYLAND_DISPLAY=wayland-0
```

3. Encontrá los procesos que realmente implementan el escritorio:

```bash
station$ ps -eo pid,comm --sort=comm | grep -E 'gnome-shell|mutter|plasmashell|kwin|xfwm4|xfdesktop|Xorg|Xwayland'
```

```
   1893 Xwayland
   1721 gnome-shell
```

4. Enumerá todas las sesiones que el gestor de inicio de sesión puede ofrecer, y leé una de ellas:

```bash
station$ ls /usr/share/xsessions/ /usr/share/wayland-sessions/
station$ cat /usr/share/xsessions/xfce.desktop
```

```
/usr/share/wayland-sessions/:
gnome.desktop  plasmawayland.desktop

/usr/share/xsessions/:
gnome-xorg.desktop  plasmax11.desktop  xfce.desktop

[Desktop Entry]
Version=1.0
Name=Xfce Session
Comment=Use this session to run Xfce as your desktop environment
Exec=startxfce4
Icon=
Type=Application
DesktopNames=XFCE
```

5. Confirmá qué informa el gestor de ventanas sobre sí mismo (solo sesiones X11 y Xwayland):

```bash
station$ wmctrl -m
```

```
Name: GNOME Shell
Class: N/A
PID: N/A
Window manager's "showing the desktop" mode: N/A
```

**Comprobá lo que entendiste — Bloque 1**

1.1 `$XDG_SESSION_TYPE` dice `wayland`, y sin embargo `echo $DISPLAY` imprime `:0` y `xterm` arranca normalmente. Explicá, con precisión, qué está sirviendo ese `:0`.
1.2 ¿Cuál de estos tres valores lo establece el *archivo `.desktop` de la sesión* y no logind: `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_VTNR`?
1.3 Estás conectado por SSH plano, sin reenvío de X. `loginctl show-session auto -p Type` devuelve `Type=tty` y `$XDG_CURRENT_DESKTOP` está vacío, aunque hay un usuario con sesión iniciada físicamente en GNOME en la consola. ¿Por qué, y cómo inspeccionás *esa* sesión en su lugar?
1.4 ¿Cuál es la diferencia funcional entre los directorios `/usr/share/xsessions/` y `/usr/share/wayland-sessions/`?

---

## Bloque 2 — El gestor de pantalla: qué arranca el escritorio

1. Identificá el gestor de pantalla (DM) en ejecución a través del alias canónico:

```bash
srv$ systemctl status display-manager --no-pager | head -3
srv$ ls -l /etc/systemd/system/display-manager.service
```

```
● gdm.service - GNOME Display Manager
     Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: disabled)
     Active: active (running) since Tue 2026-08-25 09:12:44 -03; 1 day 4h ago

lrwxrwxrwx. 1 root root 36 Aug 12 18:03 /etc/systemd/system/display-manager.service -> /usr/lib/systemd/system/gdm.service
```

Ese symlink **es** el mecanismo. No existe un archivo de unidad `display-manager.service`; la distribución crea un symlink hacia el DM que esté seleccionado, y `graphical.target` incorpora el alias.

2. Confirmá el target de arranque que decide si un DM arranca siquiera:

```bash
srv$ systemctl get-default
srv$ systemctl list-dependencies graphical.target --no-pager | head -8
```

```
graphical.target
graphical.target
● ├─display-manager.service
● ├─gdm.service
● └─multi-user.target
```

3. Cambiá de runlevel/target sin reiniciar, y observá:

```bash
srv$ sudo systemctl isolate multi-user.target     # DM stops, graphical sessions die
srv$ systemctl is-active display-manager
srv$ sudo systemctl isolate graphical.target      # DM comes back
```

```
inactive
```

4. Cambiá el DM por defecto. Instalá un segundo y reapuntá el alias:

```bash
srv$ sudo apt-get install -y lightdm        # Debian/Ubuntu: offers an interactive chooser
srv$ sudo dpkg-reconfigure lightdm
```

En Fedora/RHEL/openSUSE no hay selector de debconf — manipulás las unidades directamente:

```bash
srv$ sudo systemctl disable gdm
srv$ sudo systemctl enable sddm            # recreates the display-manager.service symlink
srv$ ls -l /etc/systemd/system/display-manager.service
```

5. Hacé que el arranque por defecto sea en modo texto, y después iniciá un escritorio a mano desde la consola — la vía sin DM:

```bash
srv$ sudo systemctl set-default multi-user.target
srv$ cat ~/.xinitrc
srv$ startx
```

```
exec startxfce4
```

**Comprobá lo que entendiste — Bloque 2**

2.1 Editaste `/etc/systemd/system/display-manager.service` a mano para que apunte a SDDM, después corriste `apt-get upgrade`, y tras reiniciar volvió GDM. ¿Cuál es la forma soportada de hacer que la elección persista en Debian?
2.2 `systemctl get-default` devuelve `graphical.target` pero la máquina arranca en un login de texto. Dá tres causas distintas, en el orden en que las probarías.
2.3 ¿Qué usa `startx` para decidir qué escritorio ejecutar, y en qué se diferencia de lo que usa un gestor de pantalla?
2.4 Un usuario reporta "el escritorio se reinició y perdí mi trabajo". `systemctl status display-manager` muestra un uptime de 4 minutos. ¿Qué único comando de log te muestra por qué?

---

## Bloque 3 — KDE Plasma, GNOME y Xfce: los mismos roles, distintas implementaciones

Un entorno de escritorio no es un monolito; es un conjunto fijo de roles cubiertos por programas distintos. Aprendé el mapa de roles una vez y todo DE se vuelve legible.

1. Instalá Xfce junto a tu escritorio actual para poder comparar (esto es seguro; solo agrega una sesión):

```bash
srv$ sudo apt-get install -y xfce4 xfce4-goodies       # Debian/Ubuntu
srv$ sudo dnf group install -y "Xfce Desktop"          # Fedora
```

2. Cerrá sesión, seleccioná **Xfce Session** en el greeter, volvé a iniciar sesión, y mapeá los componentes en ejecución a sus roles:

```bash
srv$ ps -eo comm= --sort=comm | grep -E 'xfwm4|xfdesktop|xfce4-panel|xfsettingsd|Thunar|xfce4-session'
```

```
Thunar
xfce4-panel
xfce4-session
xfdesktop
xfsettingsd
xfwm4
```

3. Leé y cambiá una configuración a través del sistema de configuración nativo de cada DE. Xfce usa **Xfconf** (XML bajo `~/.config/xfce4/xfconf/`):

```bash
srv$ xfconf-query -c xfwm4 -l -v | head -5
srv$ xfconf-query -c xfwm4 -p /general/theme -s Default-hdpi
```

```
/general/activate_action        bring
/general/borderless_maximize    true
/general/box_move               false
/general/button_layout          O|SHMC
/general/click_to_focus         true
```

GNOME usa **GSettings** sobre la base de datos binaria **dconf** (`~/.config/dconf/user`):

```bash
srv$ gsettings get org.gnome.desktop.interface color-scheme
srv$ gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
srv$ gsettings list-recursively org.gnome.desktop.wm.preferences | head -4
```

```
'default'
org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
org.gnome.desktop.wm.preferences audible-bell false
org.gnome.desktop.wm.preferences button-layout 'appmenu:close'
org.gnome.desktop.wm.preferences focus-mode 'click'
```

KDE Plasma usa **KConfig**, archivos INI planos bajo `~/.config/*rc`:

```bash
srv$ kreadconfig5 --file kdeglobals --group General --key ColorScheme
srv$ kwriteconfig5 --file kwinrc --group Windows --key FocusPolicy FocusFollowsMouse
srv$ qdbus org.kde.KWin /KWin reconfigure         # make KWin re-read kwinrc live
```

4. Construí el mapa de roles por inspección:

| Rol | GNOME | KDE Plasma | Xfce |
|---|---|---|---|
| Compositor / gestor de ventanas | Mutter (dentro de `gnome-shell` en Wayland) | KWin (`kwin_wayland` / `kwin_x11`) | `xfwm4` (solo X11) |
| Shell / panel | `gnome-shell` | `plasmashell` | `xfce4-panel` + `xfdesktop` |
| Gestor de sesión | `gnome-session` | `startplasma-*` / `ksmserver` | `xfce4-session` |
| Gestor de archivos | Nautilus (GNOME Files) | Dolphin | Thunar |
| Almacén de configuración | GSettings → dconf | KConfig → `~/.config/*rc` | Xfconf → XML |
| Toolkit de widgets | GTK | Qt | GTK |
| Gestor de pantalla que suele venir | GDM | SDDM | LightDM |

5. Verificá empíricamente la afirmación sobre el toolkit:

```bash
srv$ ldd $(which dolphin) 2>/dev/null | grep -c libQt
srv$ ldd $(which thunar)  | grep -c libgtk
```

**Comprobá lo que entendiste — Bloque 3**

3.1 En una sesión GNOME **Wayland**, `ps` no muestra ningún proceso separado de gestor de ventanas. ¿Adónde fue Mutter, y qué cambia respecto del comportamiento ante caídas comparado con una sesión X11 corriendo `metacity`?
3.2 Una configuración de GNOME de un usuario no persiste entre reinicios. `gsettings set` tiene éxito y `gsettings get` refleja el cambio inmediatamente. ¿Qué archivo revisarías en cuanto a integridad, y qué comando vuelca toda la base de datos como texto?
3.3 Xfce y GNOME usan ambos GTK. Nombrá dos razones concretas por las que una aplicación GNOME puede igualmente verse y comportarse mal bajo Xfce.
3.4 Tenés que aplicar una configuración de KDE a 400 estaciones de trabajo desde un script de shell, sin ningún usuario con sesión iniciada. ¿Cuál de `kwriteconfig5`, `gsettings` o `xfconf-query` es *intrínsecamente* la menos problemática en ese escenario, y por qué?

---

## Bloque 4 — X11 como protocolo de red: `$DISPLAY`, autoridad X, reenvío por SSH

X11 es el único de los cinco protocolos de este objetivo que es *nativamente* transparente a la red al nivel de ventanas individuales. Todo el resto transporta píxeles de una pantalla completa.

1. Descomponé la especificación de display. La sintaxis es `hostname:displaynumber.screennumber`:

```bash
station$ echo $DISPLAY
station$ xdpyinfo | head -6
```

```
:0
name of display:    :0
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12401007
X.Org version: 24.1.7
maximum request size:  16777212 bytes
```

Un hostname vacío significa un **socket de dominio UNIX** — miralo:

```bash
station$ ls -l /tmp/.X11-unix/
```

```
srwxrwxrwx. 1 root root 0 Aug 25 09:12 X0
```

2. Inspeccioná la credencial de control de acceso. La autorización de X11 es un secreto compartido, la **MIT-MAGIC-COOKIE-1**, almacenada en el archivo nombrado por `$XAUTHORITY`:

```bash
station$ echo $XAUTHORITY
station$ xauth list
```

```
/run/user/1000/.mutter-Xwaylandauth.T2K9J2
station/unix:0  MIT-MAGIC-COOKIE-1  9f2a41c7b8de05631aa47c9e2b0d5f88
```

3. Mirá el *otro* mecanismo de control de acceso, más grueso, basado en host:

```bash
station$ xhost
```

```
access control enabled, only authorized clients can connect
SI:localuser:alice
```

4. Verificá que ningún servidor X esté escuchando en TCP — el valor por defecto moderno:

```bash
station$ ss -ltnp | grep -E ':60[0-9][0-9]'
station$ ps -eo args= | grep -o '\-nolisten tcp'
```

```
-nolisten tcp
```

Un primer resultado vacío es correcto y esperable. TCP 6000+N está deshabilitado porque X11 crudo sobre el cable no está cifrado ni autenticado más allá de la cookie.

5. Ahora hacelo de la manera soportada: tunelizá X11 dentro de SSH. En `srv`, confirmá el lado servidor:

```bash
srv$ sudo sshd -T | grep -E '^x11(forwarding|displayoffset|uselocalhost)'
```

```
x11forwarding yes
x11displayoffset 10
x11uselocalhost yes
```

Si `x11forwarding` está en `no`, poné `X11Forwarding yes` en `/etc/ssh/sshd_config` y `sudo systemctl reload sshd`.

6. Conectate y observá cómo se crea el display reenviado:

```bash
station$ ssh -X alice@srv
srv$ echo $DISPLAY
srv$ xauth list
srv$ ss -ltnp | grep 6010
srv$ xeyes &
```

```
localhost:10.0
srv/unix:10  MIT-MAGIC-COOKIE-1  4b1c7e93aa0f2d6851ce33907b4ad2f1
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=4471,fd=9))
```

`xeyes` corre en `srv`, dibuja en `station`. Notá que la cookie en `srv` es una cookie *proxy* acuñada por sshd, no la tuya real — sshd la sustituye en cada conexión reenviada.

7. Compará el reenvío confiable y el no confiable:

```bash
station$ ssh -X  alice@srv 'xdotool key --window $(xdotool getactivewindow) a' ; echo "untrusted rc=$?"
station$ ssh -Y  alice@srv 'xdotool key --window $(xdotool getactivewindow) a' ; echo "trusted   rc=$?"
```

`-X` (no confiable) activa la extensión X11 SECURITY, que bloquea operaciones como leer las ventanas de otros clientes, capturas globales de teclado y espionaje del portapapeles. `-Y` (`ForwardX11Trusted yes`) desactiva esas restricciones — la aplicación remota gana control total de tu display local.

8. Reproducí deliberadamente las dos fallas clásicas:

```bash
srv$ DISPLAY= xeyes
srv$ XAUTHORITY=/dev/null xeyes
```

```
Error: Can't open display:
No protocol specified
Error: Can't open display: localhost:10.0
```

**Comprobá lo que entendiste — Bloque 4**

4.1 En `$DISPLAY=srv.example.com:2.1`, ¿qué selecciona cada uno de los tres campos, y qué puerto TCP usaría una conexión directa (no tunelizada)?
4.2 Distinguí con precisión la falla `Can't open display:` de `No protocol specified / Can't open display: localhost:10.0`. ¿Cuál es un problema de autorización?
4.3 `xhost +` es un "arreglo" muy común que se encuentra en internet. Indicá exactamente qué permite y por qué es inaceptable en un host multiusuario o alcanzable por red.
4.4 Con `ssh -X`, ¿en qué máquina corre el **cliente** X, y en qué máquina corre el **servidor** X? Justificá la respuesta en términos de quién es dueño del hardware de display.
4.5 Necesitás ejecutar una aplicación GUI remota que requiere una captura global de teclado (un gestor de contraseñas). `-X` la rompe. ¿Cuáles son tus dos opciones y cuál es la consecuencia de seguridad de cada una?
4.6 Un usuario en una sesión GNOME Wayland ejecuta `ssh -X srv` y las apps GUI remotas funcionan bien. ¿Qué componente local está aceptando esas conexiones X11?

---

## Bloque 5 — XDMCP: intermediar sesiones completas hacia un terminal X

XDMCP (X Display Manager Control Protocol) invierte la topología del reenvío por SSH. La **máquina cliente ejecuta el servidor X**, y luego le pide a un gestor de pantalla remoto por **UDP 177** que le envíe un greeter de inicio de sesión y ejecute la sesión completa de forma remota. Es el clásico protocolo de cliente ligero / terminal X y está **totalmente sin cifrar**.

1. Habilitá XDMCP en `srv`. Con LightDM:

```bash
srv$ sudo tee /etc/lightdm/lightdm.conf.d/50-xdmcp.conf >/dev/null <<'EOF'
[XDMCPServer]
enabled=true
port=177
EOF
srv$ sudo systemctl restart lightdm
```

Con GDM, el equivalente vive en `/etc/gdm3/custom.conf` (Debian) o `/etc/gdm/custom.conf` (Fedora):

```ini
[xdmcp]
Enable=true

[security]
DisallowTCP=false
```

2. Verificá el listener y abrí el puerto. XDMCP es **UDP**, así que `ss -ltn` nunca lo va a mostrar:

```bash
srv$ sudo ss -lunp | grep :177
srv$ sudo firewall-cmd --add-service=xdmcp --permanent && sudo firewall-cmd --reload
```

```
UNCONN 0  0  0.0.0.0:177  0.0.0.0:*  users:(("lightdm",pid=1177,fd=13))
```

3. Desde `station`, conectale un servidor X anidado — la forma segura de probar sin abandonar tu escritorio:

```bash
station$ Xephyr :3 -query srv -screen 1280x800 -once
```

Se abre una ventana que contiene el greeter remoto. Iniciá sesión; todo el escritorio corre en `srv`, renderizado en `station`.

4. La forma histórica sobre hardware desnudo, desde una consola de texto (VT 8), donde la máquina cliente es un terminal X dedicado:

```bash
station$ sudo X -query srv :3 vt8
```

5. Preguntale a la red quién está ofreciendo sesiones (consulta por broadcast):

```bash
station$ Xephyr :3 -broadcast -screen 1024x768 -once
```

6. Ahora demostrá la afirmación sobre seguridad. Mientras estás con sesión iniciada a través de la sesión de Xephyr, capturá tráfico en `srv`:

```bash
srv$ sudo tcpdump -i any -A 'port 177 or portrange 6000-6010' -c 20
```

Vas a ver datos de protocolo legibles. Las pulsaciones de teclas atraviesan el flujo X11 en TCP 6000+N en texto plano; XDMCP en sí solo intermedia la sesión.

7. Limpieza — dejalo deshabilitado:

```bash
srv$ sudo rm /etc/lightdm/lightdm.conf.d/50-xdmcp.conf
srv$ sudo systemctl restart lightdm
srv$ sudo firewall-cmd --remove-service=xdmcp --permanent && sudo firewall-cmd --reload
```

**Comprobá lo que entendiste — Bloque 5**

5.1 En una sesión XDMCP, ¿qué host ejecuta el servidor X, cuál ejecuta el gestor de pantalla, y cuál ejecuta `gnome-shell`?
5.2 XDMCP usa UDP 177, pero deshabilitarlo no alcanza para asegurar el montaje. ¿Qué *otros* puertos hay que considerar también, y qué transporta las pulsaciones de teclas del usuario?
5.3 `ss -ltnp | grep 177` no devuelve nada en un servidor XDMCP correctamente configurado. ¿Por qué eso no es una falla, y cuál es el comando correcto?
5.4 Habilitar `[xdmcp] Enable=true` en GDM no tiene efecto y el greeter nunca aparece de forma remota. Nombrá dos razones estructurales por las que esto pasa en una distribución actual.
5.5 Contrastá XDMCP con `ssh -X` en términos de (a) qué se remotiza, (b) confidencialidad, (c) qué lado necesita un servidor X.

---

## Bloque 6 — VNC: remotizar un framebuffer con RFB

VNC (Virtual Network Computing) habla **RFB** (Remote Framebuffer, RFC 6143). Es agnóstico del servidor gráfico y orientado a píxeles: transporta rectángulos de pantalla, no comandos de dibujo. Importan dos modos de despliegue, y confundirlos es el error de VNC más común de todos.

### 6a — Modo de sesión virtual (un escritorio *nuevo*, sin cabeza)

1. Instalá TigerVNC y establecé una contraseña:

```bash
srv$ sudo dnf install -y tigervnc-server        # or: apt-get install tigervnc-standalone-server
srv$ vncpasswd
```

```
Password:
Verify:
Would you like to enter a view-only password (y/n)? n
```

2. Configurá la sesión por usuario:

```bash
srv$ cat > ~/.vnc/config <<'EOF'
geometry=1280x800
depth=24
localhost
session=xfce
EOF
srv$ chmod 600 ~/.vnc/passwd
```

3. Mapeá números de display a usuarios (modelo systemd de TigerVNC ≥ 1.11) y arrancalo:

```bash
srv$ echo ':1=alice' | sudo tee -a /etc/tigervnc/vncserver.users
srv$ sudo systemctl enable --now vncserver@:1
srv$ systemctl status vncserver@:1 --no-pager | head -4
```

4. Confirmá la aritmética de puertos. **Puerto = 5900 + número de display**:

```bash
srv$ ss -ltnp | grep 590
```

```
LISTEN 0 5 127.0.0.1:5901 0.0.0.0:* users:(("Xvnc",pid=5231,fd=8))
```

`:1` → 5901. Ligado a loopback por el `localhost` en `~/.vnc/config`.

5. Alcanzalo desde `station` a través de un túnel SSH — la forma correcta de exponer VNC:

```bash
station$ ssh -f -N -L 5901:localhost:5901 alice@srv
station$ vncviewer localhost:5901
```

6. Inspeccioná el script de arranque de la sesión y su log cuando algo sale mal:

```bash
srv$ cat ~/.vnc/xstartup
srv$ tail -20 ~/.vnc/srv:1.log
```

```
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
```

Una pantalla gris en blanco con un cursor X significa que `xstartup` se ejecutó pero no inició **ningún gestor de ventanas**.

### 6b — Modo espejo (compartir la sesión de consola *existente*)

7. `Xvnc` crea un escritorio completamente nuevo en el que no hay nadie sentado. Para tomar el display `:0`, necesitás `x11vnc`:

```bash
srv$ sudo dnf install -y x11vnc
srv$ x11vnc -storepasswd ~/.vnc/x11vnc.pass
srv$ x11vnc -display :0 -auth guess -localhost -rfbauth ~/.vnc/x11vnc.pass -forever
```

```
The X11 display :0 is being shared on port 5900
```

8. Ahora probá lo mismo en una sesión **Wayland**:

```bash
srv$ loginctl show-session auto -p Type
srv$ x11vnc -display :0 -auth guess
```

```
Type=wayland
XOpenDisplay("​:0") failed.
Xlib: connection to ":0" refused by server
```

Esto no es un bug. `x11vnc` raspa una ventana raíz de X11; un compositor Wayland no expone ninguna. El reemplazo soportado es el backend de compartición de pantalla del propio compositor (`gnome-remote-desktop`, el servidor `krfb`/RDP de KDE), que usa PipeWire.

**Comprobá lo que entendiste — Bloque 6**

6.1 Un usuario pide "VNC para poder ver lo que hay en la pantalla de la oficina". Configurás `vncserver@:1`, se conecta, y ve un escritorio vacío recién creado en lugar de la pantalla de la oficina. ¿Qué hiciste mal, y qué desplegás en su lugar?
6.2 Calculá el puerto TCP para el display VNC `:4`. ¿Qué escucha en 5800 en algunos montajes heredados?
6.3 El archivo de contraseña de VNC es `~/.vnc/passwd`. Hay dos hechos sobre él que son relevantes para el examen y para la seguridad. Indicá ambos.
6.4 `systemctl status vncserver@:1` informa activo, pero `vncviewer srv:5901` desde otro host da timeout mientras que `vncviewer localhost:5901` en `srv` funciona. Dá las dos causas más probables y el comando que discrimina entre ellas.
6.5 ¿Por qué se considera obligatorio un túnel SSH para VNC sobre una red no confiable, dado que VNC sí tiene contraseña?
6.6 Explicá, en términos de protocolo, por qué RFB funciona idénticamente contra un servidor Linux, Windows o macOS mientras que el reenvío de X11 no.

---

## Bloque 7 — RDP: xrdp, FreeRDP y la vía moderna de Wayland

RDP (Remote Desktop Protocol) es el protocolo de Microsoft, escuchando en **TCP 3389**. En Linux es el de mejor rendimiento sobre enlaces de alta latencia y el único de los cinco con redirección de dispositivos madura (unidades, impresoras, tarjetas inteligentes, audio, portapapeles) integrada en el protocolo mismo.

1. Instalá e inspeccioná el servidor:

```bash
srv$ sudo dnf install -y xrdp        # or: apt-get install xrdp
srv$ sudo systemctl enable --now xrdp
srv$ systemctl status xrdp xrdp-sesman --no-pager | grep -E 'Active|●'
srv$ ss -ltnp | grep 3389
```

```
LISTEN 0 2 0.0.0.0:3389 0.0.0.0:* users:(("xrdp",pid=6104,fd=11))
```

Dos unidades, dos roles: `xrdp` termina el protocolo en 3389; `xrdp-sesman` es el gestor de sesión que autentica vía PAM y lanza el escritorio.

2. Leé la configuración clave:

```bash
srv$ grep -vE '^\s*(#|$)' /etc/xrdp/xrdp.ini | head -20
srv$ cat /etc/xrdp/startwm.sh | tail -8
```

```
[Globals]
ini_version=1
port=3389
security_layer=negotiate
crypt_level=high
certificate=
key_file=
...
[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
port=-1
code=20
```

3. Fijá el escritorio que reciben las sesiones RDP:

```bash
srv$ echo 'startxfce4' | sudo tee /etc/xrdp/startwm.sh.d/50-xfce.sh   # distro-dependent
srv$ echo 'xfce4-session' > ~/.xsession
srv$ sudo systemctl restart xrdp
```

4. Abrí el firewall y conectate desde `station`:

```bash
srv$ sudo firewall-cmd --add-port=3389/tcp --permanent && sudo firewall-cmd --reload
station$ xfreerdp /v:srv /u:alice /dynamic-resolution +clipboard /cert:ignore
```

Con FreeRDP 3 el binario es `xfreerdp3` y los flags tienen espacio de nombres:

```bash
station$ xfreerdp3 /v:srv /u:alice /dynamic-resolution +clipboard /sound /drive:home,/home/alice
```

5. Comprobá que la redirección de dispositivos realmente funciona — dentro de la sesión RDP en `srv`:

```bash
srv$ ls ~/thinclient_drives/home | head
```

6. Usá la alternativa nativa de Wayland. GNOME trae su propio servidor RDP (`gnome-remote-desktop`), que es la forma soportada de compartir una sesión Wayland:

```bash
srv$ grdctl status
srv$ grdctl rdp enable
srv$ grdctl rdp set-credentials alice 'S3cret!'
srv$ grdctl rdp disable-view-only
srv$ systemctl --user enable --now gnome-remote-desktop
srv$ ss -ltnp | grep 3389
```

Notá que esta es una unidad de **usuario** para una compartición sin cabeza/de sesión, y colisiona con `xrdp` en 3389 — ejecutá uno u otro.

7. Diagnosticá la falla "pantalla azul y después desconexión", que es el error característico de xrdp:

```bash
srv$ sudo journalctl -u xrdp-sesman -n 30 --no-pager
srv$ tail -20 ~/.xorgxrdp.10.log
srv$ tail -20 /var/log/xrdp-sesman.log
```

**Comprobá lo que entendiste — Bloque 7**

7.1 `xrdp` y `xrdp-sesman` son servicios separados. ¿Qué hace cada uno, y cuál de los dos autentica al usuario?
7.2 ¿Qué puerto TCP es RDP, y qué pasa si habilitás tanto `xrdp` como `gnome-remote-desktop` en el mismo host?
7.3 Nombrá dos capacidades que RDP provee nativamente y que VNC (RFB) plano no.
7.4 Un inicio de sesión RDP tiene éxito, y después la sesión vuelve a la caja de login a los dos segundos. ¿Qué dos archivos de log leés primero?
7.5 Tu `srv` corre GNOME sobre Wayland y tenés que darle a un usuario de Windows acceso al escritorio *actualmente con sesión iniciada*. ¿Cuál de `x11vnc`, `xrdp` con el backend Xorg, o `gnome-remote-desktop` es la respuesta correcta, y por qué las otras dos están mal?

---

## Bloque 8 — SPICE: el protocolo de consola de máquinas virtuales

SPICE (Simple Protocol for Independent Computing Environments) no es un protocolo de escritorio remoto general para máquinas físicas. Está diseñado para **máquinas virtuales**: el hipervisor expone el dispositivo gráfico emulado del huésped, y un protocolo multicanal transporta display, entrada, audio, redirección USB y portapapeles, cada uno en su propio canal.

1. Arrancá un huésped QEMU con un display SPICE ligado a loopback:

```bash
srv$ qemu-system-x86_64 -enable-kvm -m 2048 -hda /var/lib/libvirt/images/test.qcow2 \
    -vga qxl \
    -spice port=5930,addr=127.0.0.1,disable-ticketing=on \
    -device virtio-serial-pci \
    -chardev spicevmc,id=spicechannel0,name=vdagent \
    -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0
```

2. Verificá el listener y conectate:

```bash
srv$ ss -ltnp | grep 5930
srv$ remote-viewer spice://127.0.0.1:5930
```

```
LISTEN 0 1 127.0.0.1:5930 0.0.0.0:* users:(("qemu-system-x86",pid=7712,fd=17))
```

3. En el caso gestionado por libvirt, no adivines la URI — preguntá:

```bash
srv$ virsh list --all
srv$ virsh domdisplay win11
srv$ virsh dumpxml win11 | grep -A3 '<graphics'
```

```
spice://127.0.0.1:5900

    <graphics type='spice' port='5900' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
      <image compression='off'/>
    </graphics>
```

4. Alcanzá una consola SPICE ligada a loopback desde `station` — la misma disciplina de tunelización que VNC, o el transporte incorporado de `virt-viewer`:

```bash
station$ remote-viewer --spice-debug spice://srv:5930           # only if listen is 0.0.0.0
station$ virt-viewer --connect qemu+ssh://alice@srv/system win11
```

5. Instalá el agente de huésped **dentro del huésped** y observá qué habilita:

```bash
guest$ sudo dnf install -y spice-vdagent
guest$ sudo systemctl enable --now spice-vdagentd
guest$ systemctl status spice-vdagentd --no-pager | head -3
```

Sin `spice-vdagent` no hay compartición de portapapeles, ni ajuste automático de la resolución del huésped cuando redimensionás la ventana del visor, ni cambio suave de modo de mouse. Esta es la pregunta de soporte de SPICE que más se hace.

6. Compará con la misma VM expuesta por VNC en su lugar:

```bash
srv$ virsh dumpxml win11 | sed 's|type=.spice.|type="vnc"|' > /tmp/win11-vnc.xml
```

La consola VNC te da el mismo framebuffer pero pierde redirección USB, multi-monitor y audio.

**Comprobá lo que entendiste — Bloque 8**

8.1 SPICE y VNC pueden ambos actuar como display de QEMU. Indicá tres capacidades que SPICE tiene y el display VNC de QEMU no.
8.2 ¿Cuál es el rol de `spice-vdagent`, de qué lado de la conexión corre, y nombrá dos síntomas de su ausencia.
8.3 `virsh domdisplay vm1` imprime `spice://127.0.0.1:5900`, y sin embargo `remote-viewer spice://srv:5900` desde otro host no logra conectar. Explicá, y dá los dos remedios posibles.
8.4 ¿Por qué SPICE es una elección extraña para remotizar el escritorio de una estación de trabajo física?
8.5 `disable-ticketing=on` aparece en la línea de comandos de QEMU de arriba. ¿Qué deshabilitó, y por qué nunca debe aparecer en un listener que no sea de loopback?

---

## Bloque 9 — Elegir el protocolo, y un ejercicio de diagnóstico

1. Construí la tabla de decisión vos mismo antes de leerla. Para cada protocolo completá: puerto y transporte por defecto, qué unidad de trabajo se remotiza, si está cifrado por defecto, y si puede engancharse a una sesión local ya en ejecución.

```bash
station$ printf '%-8s %-14s %-22s %-12s %s\n' PROTO PORT UNIT ENCRYPTED ATTACH-TO-:0
```

| Protocolo | Puerto por defecto | Qué se remotiza | Cifrado por defecto | Puede engancharse a una sesión local en ejecución |
|---|---|---|---|---|
| **X11** (directo) | TCP 6000+N | Ventanas individuales (comandos de dibujo) | No | n/a — el cliente dibuja en tu display |
| **X11 sobre SSH** | TCP 22 | Ventanas individuales | **Sí** (SSH) | n/a |
| **XDMCP** | **UDP 177** (+ X11 en TCP 6000+N) | Una sesión nueva completa; el cliente aporta el servidor X | No | No — siempre una sesión nueva |
| **VNC / RFB** | TCP 5900+N | Rectángulos de framebuffer | No (solo contraseña; TLS vía extensiones) | Solo con `x11vnc`, y solo en X11 |
| **RDP** | TCP 3389 | Framebuffer + canales de dispositivos/audio/portapapeles | **Sí** (TLS/CredSSP) | Sí (`gnome-remote-desktop`, xrdp con un backend espejo) |
| **SPICE** | TCP 5900+ (definido por el sitio, p. ej. 5930) | Display de la VM + dispositivos multicanal | TLS opcional | n/a — se engancha a un *huésped*, no a una sesión de host |

2. Ejercicio de diagnóstico. Para cada síntoma, escribí el *primer* comando que ejecutás, y después verificá contra las respuestas.

```
A. "Remote GUI over ssh -X does nothing: Error: Can't open display:"
B. "VNC viewer says 'connection refused' from the LAN, works on the server itself."
C. "xrdp accepts the password then throws me back to the login box."
D. "SPICE viewer connects but the clipboard does not work and resizing does nothing."
E. "x11vnc exits with 'XOpenDisplay failed' on a freshly installed workstation."
F. "The XDMCP greeter never appears; tcpdump on the server shows no traffic at all."
```

3. Ejecutá el barrido inicial universal en `srv` y leelo como un todo:

```bash
srv$ ss -ltnp | grep -E ':(3389|59[0-9][0-9]|60[0-9][0-9])'
srv$ sudo ss -lunp | grep :177
srv$ sudo firewall-cmd --list-all | grep -E 'ports|services'
srv$ loginctl list-sessions
srv$ journalctl -b -u display-manager -u xrdp -u xrdp-sesman -p warning --no-pager | tail -20
```

**Comprobá lo que entendiste — Bloque 9**

9.1 Respondé los seis ítems A–F del ejercicio con el único primer comando más informativo para cada uno.
9.2 Una sucursal se conecta por un enlace satelital de 180 ms y necesita un escritorio completo con impresión local. Ordená X11-sobre-SSH, VNC y RDP para este caso y justificá el orden por razones de protocolo, no de preferencia.
9.3 ¿Cuáles dos de los cinco protocolos **no** crean una sesión nueva sino que se enganchan a un display existente, y bajo qué condiciones exactamente?
9.4 Solo un protocolo de este objetivo transporta primitivas de dibujo en lugar de píxeles. ¿Cuál, y cuál es la consecuencia práctica para el ancho de banda en una pantalla mayormente estática frente a la reproducción de video?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**1.1** `Xwayland` está sirviendo `:0`. En una sesión Wayland el compositor (Mutter, KWin) inicia un servidor X sin raíz, Xwayland, que se presenta como un display X común para que los clientes X11 heredados sigan funcionando. Esos clientes hablan X11 con Xwayland, que traduce sus superficies a superficies Wayland para el compositor. `$DISPLAY` está por lo tanto definido aunque el tipo de sesión sea `wayland`.

**1.2** `XDG_CURRENT_DESKTOP`. Viene de la clave `DesktopNames=` del archivo `.desktop` de la sesión (o lo exporta el script de arranque de la sesión). `XDG_SESSION_TYPE` y `XDG_VTNR` los establece `systemd-logind` / PAM cuando se crea la sesión.

**1.3** Tu inicio de sesión por SSH es su propia sesión de logind, de clase `user` y tipo `tty`; `auto` resuelve a *esa* sesión, no a la de consola. Las variables de entorno son por proceso, así que no podés ver el `XDG_CURRENT_DESKTOP` de la sesión de consola desde tu shell en absoluto. Inspeccioná la otra sesión explícitamente:

```bash
loginctl list-sessions
loginctl show-session 2 -p Type -p Class -p Desktop -p Active -p Name
loginctl user-status alice
```

**1.4** Son los catálogos que lee el gestor de pantalla para armar su selector de sesiones. Las entradas en `/usr/share/xsessions/` se inician bajo un servidor gráfico Xorg; las de `/usr/share/wayland-sessions/` se inician como compositores Wayland nativos. Mismo formato de archivo, distinto entorno de ejecución.

### Bloque 2

**2.1** El symlink es generado. En Debian la selección se registra en `/etc/X11/default-display-manager` (que contiene la ruta completa del binario del DM) y la aplican los scripts postinst de los paquetes de DM; la interfaz soportada es `sudo dpkg-reconfigure gdm3` (o cualquier DM instalado), que reescribe ese archivo *y* el symlink. Editar el symlink a mano se sobrescribe en la siguiente operación de paquetes.

**2.2** En orden de costo de comprobación:
1. El gestor de pantalla está enmascarado o falló — `systemctl status display-manager; systemctl is-enabled display-manager`.
2. No hay ningún DM instalado, así que `graphical.target` se alcanza sin incorporar ninguno — `ls -l /etc/systemd/system/display-manager.service`.
3. Una anulación en la línea de comandos del kernel está forzando el target — `cat /proc/cmdline` buscando `systemd.unit=multi-user.target`, `3`, o `nomodeset`/un driver de GPU roto que impide que el DM arranque (`journalctl -b -u display-manager`).

**2.3** `startx` ejecuta `~/.xinitrc`, recurriendo a `/etc/X11/xinit/xinitrc`; el escritorio es lo que ese script haga con `exec`, y no hay selector. Un gestor de pantalla lee los archivos `.desktop` bajo `/usr/share/xsessions/` y `/usr/share/wayland-sessions/`, los presenta en un greeter, y ejecuta la línea `Exec=` de la entrada seleccionada — con la última elección del usuario normalmente cacheada (p. ej. en `~/.dmrc` o por AccountsService).

**2.4** `journalctl -b -u display-manager --no-pager` (agregá `-u gdm`/`-u sddm` si el alias es ambiguo). Una caída del compositor o del greeter queda registrada ahí junto con el reinicio.

### Bloque 3

**3.1** Mutter ya no es un proceso separado: en una sesión Wayland `gnome-shell` enlaza Mutter como biblioteca y *es* el compositor, el gestor de ventanas y la shell en un mismo espacio de direcciones. Consecuencia: no hay un WM independiente que reiniciar. Bajo X11 podés matar y reiniciar `metacity`/`mutter` y conservar tus aplicaciones y la sesión; bajo Wayland, si `gnome-shell` muere, muere el compositor, todos los clientes pierden su conexión, y toda la sesión gráfica se cae.

**3.2** `~/.config/dconf/user` — una única base de datos binaria GVDB; una corrupción pierde todo de golpe y `gsettings` puede parecer que sigue funcionando contra una copia en memoria. Volcala como texto con `dconf dump /` (y recargá con `dconf load /`). Comprobá el permiso de escritura y el espacio libre en `$HOME`.

**3.3** Dos cualesquiera de: (a) las apps GNOME dependen de `gnome-settings-daemon`/`xdg-desktop-portal-gnome` para temas, portales y diálogos de archivo, y esos no están corriendo bajo Xfce, así que tiene que estar presente `xdg-desktop-portal-gtk` en su lugar; (b) usan esquemas de GSettings/dconf que el Xfconf de Xfce nunca escribe, así que la apariencia, las fuentes y los ajustes de DPI divergen; (c) las decoraciones del lado del cliente (headerbars de GTK) las dibuja la app, no `xfwm4`, dando barras de título inconsistentes; (d) `XDG_CURRENT_DESKTOP=XFCE` hace que algunas apps GNOME deshabiliten la integración con la shell.

**3.4** `kwriteconfig5`. El almacén de respaldo de KConfig son archivos INI de texto plano bajo `~/.config/`, así que se puede escribir con seguridad con cualquier herramienta — `sed`, un módulo de gestión de configuración, o un archivo esqueleto en `/etc/skel/` — sin ningún demonio corriendo y sin sesión. `gsettings` necesita un bus de sesión dconf/D-Bus en ejecución para escribir (guionizarlo para otro usuario requiere `dbus-run-session` o escribir un perfil dconf a nivel de sistema más `dconf update`), y `xfconf-query` necesita el servicio D-Bus `xfconfd` en la sesión destino.

### Bloque 4

**4.1** `srv.example.com` es el host que ejecuta el **servidor X**; `2` es el número de display, que selecciona qué servidor X en ese host; `1` es el número de pantalla dentro de ese display (una disposición multi-cabeza expuesta como pantallas separadas). Una conexión TCP directa usaría el **6002** (6000 + número de display).

**4.2** `Can't open display:` sin nada después de los dos puntos significa que `$DISPLAY` no está definida o está vacía — el cliente no sabe *dónde* conectarse. `No protocol specified / Can't open display: localhost:10.0` significa que el cliente encontró el display y lo alcanzó, pero el servidor X rechazó la conexión: es una falla de **autorización** — una `MIT-MAGIC-COOKIE-1` faltante, ilegible o desactualizada, es decir `$XAUTHORITY` apuntando al archivo equivocado (típico después de `sudo` o `su`).

**4.3** `xhost +` deshabilita por completo el control de acceso basado en host: **cualquier** cliente, desde cualquier host que pueda alcanzar el socket o el puerto TCP del servidor X, puede conectarse sin presentar una cookie. Un cliente así puede leer el contenido de todas las ventanas, tomar capturas de pantalla, inyectar pulsaciones sintéticas en cualquier ventana, y registrar el teclado globalmente. En un host multiusuario o alcanzable por red eso es un compromiso completo de la sesión de escritorio. Usá `xhost +SI:localuser:<name>` o, mejor, copiá la cookie con `xauth`.

**4.4** El **cliente** X (la aplicación, p. ej. `xeyes`) corre en el host **remoto** `srv`. El **servidor** X corre en **`station`**, tu máquina local. La terminología está invertida respecto de la intuición porque el servidor X es el proceso que *posee y sirve el hardware de display* — teclado, mouse y pantalla — a las aplicaciones que le solicitan servicios de dibujo.

**4.5** Opción 1: `ssh -Y` (o `ForwardX11Trusted yes`), que deshabilita las restricciones de la extensión SECURITY — la aplicación remota entonces tiene acceso sin restricciones a tu display local, incluyendo leer otras ventanas y registrar todas las pulsaciones de teclas, así que solo es aceptable cuando confiás plenamente en el host remoto y en todos los que tienen root en él. Opción 2: no reenviar X11 en absoluto — usar un protocolo de sesión completa (RDP/VNC) para que las capturas de la aplicación ocurran en el display remoto, y solo píxeles crucen la red. La opción 2 es la respuesta más segura.

**4.6** Xwayland. `sshd` en `srv` abre `localhost:10`, y el tráfico X11 se tuneliza de vuelta al `$DISPLAY=:0` de `station`, que en una sesión GNOME Wayland lo sirve Xwayland dentro de `gnome-shell`.

### Bloque 5

**5.1** El servidor X corre en la máquina **cliente/terminal** (la que está frente al usuario). El gestor de pantalla corre en el **servidor** y responde la consulta XDMCP. `gnome-shell` — y toda otra aplicación — también corre en el **servidor**; solo la salida de renderizado y los eventos de entrada cruzan la red.

**5.2** TCP **6000+N** en la máquina cliente, porque las aplicaciones remotas se conectan de vuelta al servidor X del cliente. XDMCP en UDP 177 solo intermedia la sesión — las pulsaciones de teclas reales, el contenido de las ventanas y el portapapeles viajan por el flujo X11 sin cifrar en 6000+N. Además, el servidor X debe iniciarse *sin* `-nolisten tcp` para que esto funcione siquiera, lo que reabre el puerto que las distribuciones modernas cierran deliberadamente.

**5.3** XDMCP es un protocolo **UDP**; `ss -ltn` lista solo sockets TCP en escucha. El comando correcto es `sudo ss -lunp | grep :177` (o `sudo ss -ulpn sport = :177`).

**5.4** Dos cualesquiera de: (a) la sesión está basada en Wayland — un compositor Wayland no se puede exportar por XDMCP en absoluto, y hay que forzar GDM a Xorg (`WaylandEnable=false` en `custom.conf`); (b) las compilaciones actuales de GDM vienen con el soporte de XDMCP eliminado o deshabilitado, y SDDM nunca lo implementó — LightDM es la opción práctica; (c) no se estableció `[security] DisallowTCP=false`, así que el lado X de la conexión es rechazado; (d) el firewall descarta UDP 177.

**5.5** (a) XDMCP remotiza una sesión entera incluyendo el greeter de inicio de sesión; `ssh -X` remotiza aplicaciones individuales dentro de una sesión local ya en ejecución. (b) XDMCP es texto plano de punta a punta; `ssh -X` está cifrado dentro del canal SSH. (c) Ambos requieren un servidor X del lado **cliente** — pero con XDMCP ese servidor X además debe aceptar conexiones TCP entrantes desde el servidor, mientras que con SSH el túnel hace que toda conexión parezca originarse en localhost.

### Bloque 6

**6.1** Desplegaste el **modo de sesión virtual**: `Xvnc` (vía `vncserver@:1`) inicia un servidor X nuevo, sin cabeza, sin relación con la consola física. Para *espejar* la pantalla que está físicamente en el display `:0` necesitás un servidor de raspado de pantalla — `x11vnc -display :0` para una sesión X11, o el backend de compartición del propio compositor (`gnome-remote-desktop`, `krfb`) para una sesión Wayland.

**6.2** 5900 + 4 = **5904**. El puerto 5800+N históricamente servía el applet VNC Java/HTTP incorporado (`vncviewer` en un navegador) que traían algunos servidores VNC.

**6.3** (a) La contraseña se almacena **ofuscada con una clave DES fija y públicamente conocida, no hasheada** — cualquiera que lea el archivo puede recuperar el texto plano (herramientas del tipo `vncpwd` lo hacen en un segundo), así que debe tener modo `0600` y pertenecer al usuario. (b) La contraseña de VNC está limitada a **8 caracteres** en el esquema clásico de autenticación VNC; una entrada más larga se trunca en silencio. Es un token de acceso a un escritorio, no una credencial de cuenta de usuario, y no autentica al *servidor* frente a vos.

**6.4** Causa 1: el servidor está ligado solo a loopback (`localhost` en `~/.vnc/config`, o `-localhost`). Causa 2: un firewall está descartando el 5901. Discriminá con `ss -ltnp | grep 5901` en `srv` — si la dirección local es `127.0.0.1:5901` es el ligado; si es `0.0.0.0:5901` el socket está abierto a la red y el problema es el firewall (`sudo firewall-cmd --list-ports` / `sudo iptables -L -n`).

**6.5** La contraseña de VNC autentica la *conexión* mediante un handshake de desafío–respuesta, pero después el RFB clásico transmite el framebuffer, las pulsaciones de teclas y el portapapeles **en texto plano**. Todo lo que el usuario tipea — incluidas contraseñas de sudo y de aplicaciones — es legible en el cable, y el flujo puede modificarse en tránsito. La contraseña además es recuperable desde `~/.vnc/passwd` y está limitada a 8 caracteres. SSH (o una compilación de VNC con TLS/VeNCrypt) aporta la confidencialidad, integridad y autenticación del servidor que RFB no tiene.

**6.6** RFB está definido enteramente en términos de **rectángulos de framebuffer y eventos de entrada** — píxeles hacia adentro, teclas y eventos de puntero hacia afuera. No hace ninguna suposición sobre el sistema de ventanas que produce esos píxeles, así que cualquier plataforma capaz de capturar un framebuffer puede implementar el lado servidor. El reenvío de X11, en cambio, tuneliza el **protocolo X mismo**: la aplicación remota debe ser un cliente X enlazado contra Xlib/XCB, y el lado local debe ser un servidor X que implemente las mismas extensiones y, para cualquier cosa no trivial, fuentes y extensiones de renderizado coincidentes.

### Bloque 7

**7.1** `xrdp` es el frontal del protocolo: escucha en TCP 3389, negocia la capa de seguridad (TLS/RDP), y multiplexa los canales RDP. `xrdp-sesman` es el gestor de sesión: **autentica al usuario** (a través de PAM), y luego crea o reconecta la sesión X de respaldo (`Xorg` + `xorgxrdp`, o `Xvnc`) y ejecuta `startwm.sh`. La autenticación es tarea de `xrdp-sesman`.

**7.2** **TCP 3389.** Ambos ligan el mismo puerto, así que el que arranque segundo falla con `Address already in use` — te queda un servicio inactivo y un "connection refused" desde el cliente. Ejecutá exactamente un servidor RDP por host.

**7.3** Dos cualesquiera de: **redirección de dispositivos** nativa (unidades locales, impresoras, tarjetas inteligentes, puertos serie), redirección de **audio** en ambas direcciones, **cifrado TLS/CredSSP y autenticación por certificado del servidor** como parte del protocolo, redimensionado con **resolución dinámica**, soporte multi-monitor, y compresión con códecs bitmap/RemoteFX afinada para enlaces de alta latencia.

**7.4** `/var/log/xrdp-sesman.log` (o `journalctl -u xrdp-sesman`) para la falla de autenticación y de lanzamiento de sesión, y el log X por sesión `~/.xorgxrdp.<display>.log` (p. ej. `~/.xorgxrdp.10.log`) o `~/.xsession-errors` para un escritorio que arranca y sale inmediatamente — las más de las veces porque `startwm.sh` no encuentra gestor de ventanas, o por un problema de PolicyKit/propiedad de `~/.Xauthority` después de que el usuario fue creado por un mecanismo distinto.

**7.5** **`gnome-remote-desktop`.** Es el único de los tres que puede compartir una sesión Wayland viva: obtiene el contenido de pantalla a través de la API de screencast PipeWire del compositor e inyecta la entrada a través del compositor, y habla RDP, así que un cliente Windows de fábrica se conecta sin software adicional. `x11vnc` está mal porque raspa una ventana raíz X11 que no existe bajo Wayland. `xrdp` con el backend Xorg/`xorgxrdp` está mal porque crea una sesión X *nueva* en lugar de engancharse a la sesión Wayland en ejecución, así que el usuario de Windows vería un escritorio distinto.

### Bloque 8

**8.1** Tres cualesquiera de: **redirección de dispositivos USB** del cliente al huésped; displays **multi-monitor** en el huésped; canales de **audio** bidireccionales; **portapapeles bidireccional** y ajuste automático de la resolución del huésped vía `spice-vdagent`; detección de flujos de video con códecs con pérdida para regiones en movimiento; redirección de tarjetas inteligentes; un diseño multicanal que permite TLS y compresión por canal.

**8.2** `spice-vdagent` (más el demonio `spice-vdagentd`) corre **dentro del huésped**, comunicándose con el cliente a través de un canal virtio-serial. Síntomas de su ausencia: el portapapeles no se transfiere entre host/cliente y huésped; redimensionar la ventana del visor no cambia la resolución del huésped; el mouse queda en "modo servidor" con un desplazamiento visible o el puntero atrapado en lugar de modo mouse de cliente; el arrastrar y soltar archivos no funciona.

**8.3** El servidor SPICE está ligado a `127.0.0.1` en el hipervisor, así que no acepta conexiones desde otros hosts. Remedios: (1) dejar el ligado en loopback y tunelizar — `ssh -L 5900:localhost:5900 alice@srv` y después `remote-viewer spice://localhost:5900`, o simplemente `virt-viewer --connect qemu+ssh://alice@srv/system vm1`, que hace la tunelización por vos; (2) cambiar el `<graphics listen>` del XML del dominio libvirt a `0.0.0.0`, abrir el puerto, **y** configurar un ticket/contraseña más TLS — nunca exponer una consola con `disable-ticketing`.

**8.4** El lado servidor de SPICE lo implementa el **hipervisor** (QEMU) alrededor de un dispositivo gráfico emulado (QXL/virtio-gpu); renderiza el display virtual de un huésped, no la sesión de una máquina física. No existe un servidor SPICE soportado que se enganche a una sesión Xorg o Wayland en ejecución sobre hardware desnudo, y sus funciones avanzadas (redirección USB, ajuste de resolución) dependen de los canales virtio y del agente de huésped que solo existen en una VM. Para una estación de trabajo física, RDP o VNC es la elección apropiada.

**8.5** Deshabilitó el **ticket** de SPICE — la contraseña de conexión — así que cualquier cliente que pueda alcanzar el puerto obtiene una sesión de consola sin autenticar con control total de teclado y mouse del huésped, equivalente a acceso físico. Es tolerable solo porque el listener es `addr=127.0.0.1`. En cualquier listener que no sea de loopback le entrega la VM a la red; establecé un ticket (`-spice port=5930,password-secret=...` / `virsh` `<graphics passwd=...>` con un `passwdValidTo` corto) y habilitá TLS.

### Bloque 9

**9.1**
- **A** — `echo $DISPLAY` en el host remoto. Vacío significa que el reenvío nunca ocurrió; después comprobá `sshd -T | grep x11forwarding` en el servidor y que `xauth` esté instalado ahí.
- **B** — `ss -ltnp | grep 5901` en el servidor: `127.0.0.1:5901` es un problema de ligado, `0.0.0.0:5901` es un problema de firewall.
- **C** — `sudo journalctl -u xrdp-sesman -n 30` (después `~/.xorgxrdp.10.log`).
- **D** — `systemctl status spice-vdagentd` **dentro del huésped**.
- **E** — `loginctl show-session auto -p Type`; `Type=wayland` lo explica, y `x11vnc` es simplemente la herramienta equivocada.
- **F** — `sudo ss -lunp | grep :177` en el servidor: que no haya nada escuchando significa que XDMCP no está habilitado (o que el DM no lo soporta), no un problema de red. Si está escuchando, revisá el firewall para UDP 177.

**9.2** **RDP primero**, después **VNC**, y **X11-sobre-SSH último**. X11 es la peor elección posible en un enlace de alta latencia porque el protocolo es **intensivo en viajes de ida y vuelta** — los clientes hacen peticiones síncronas al servidor para muchas operaciones, así que cada una cuesta 180 ms y la interfaz se vuelve inusable sin importar el ancho de banda; además no tiene redirección de impresión. VNC tolera la latencia (empuja actualizaciones de framebuffer de forma asíncrona) pero no tiene redirección de impresora, tiene compresión débil comparada con RDP, y no tiene cifrado nativo. RDP gana en los tres frentes: asíncrono, comprimido agresivamente con códecs diseñados para uso WAN, cifrado nativamente, y transporta redirección de impresora y de unidades como canales del protocolo.

**9.3** **X11** y **VNC**. X11 no crea ninguna sesión — una aplicación reenviada dibuja en el servidor X que ya estás ejecutando, así que "engancharse" es inherente, pero aplica a ventanas individuales, no a una sesión existente completa. VNC se engancha a un display existente solo en modo espejo, es decir con `x11vnc -display :0` y solo cuando ese display es un servidor **X11** real (no Xwayland-bajo-un-compositor, donde no existe una ventana raíz compartible). RDP también puede engancharse, pero solo a través de una implementación integrada con el compositor como `gnome-remote-desktop`, no a través de `xrdp` de fábrica. XDMCP y SPICE siempre apuntan a una sesión nueva y a un huésped de VM, respectivamente.

**9.4** **X11.** Transporta primitivas de dibujo y peticiones del sistema de ventanas (con pixmaps e imágenes solo cuando el cliente las envía). Consecuencia: en una pantalla mayormente estática con widgets simples, X11 usa muchísimo menos ancho de banda que cualquier protocolo de framebuffer, porque no se transmite nada cuando nada cambia y un redibujado cuesta unos pocos cientos de bytes de peticiones. Durante la reproducción de video la relación se invierte gravemente — los toolkits modernos empujan pixmaps del lado del cliente ya renderizados, así que X11 termina transportando cuadros crudos o apenas comprimidos sin códec de video, mientras que VNC, RDP y SPICE aplican compresión consciente del movimiento y detectan regiones de video.

</details>

---

### Fuentes

- LPI — Exam 101-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-102-objectives/
- X.Org Foundation — `Xserver(1)`, `Xsecurity(7)`, `xauth(1)`, `xhost(1)`: https://www.x.org/releases/current/doc/man/
- X.Org Foundation — Especificación XDMCP: https://www.x.org/releases/current/doc/xorg-docs/xdmcp/xdmcp.html
- freedesktop.org — Desktop Entry Specification: https://specifications.freedesktop.org/desktop-entry-spec/latest/
- freedesktop.org — Wayland y Xwayland: https://wayland.freedesktop.org/xserver.html
- systemd — `loginctl(1)` y `systemd-logind.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- OpenSSH — `ssh(1)` / `sshd_config(5)`, reenvío de X11: https://man.openbsd.org/ssh
- IETF RFC 6143 — The Remote Framebuffer Protocol: https://www.rfc-editor.org/rfc/rfc6143
- TigerVNC — documentación y manuales de `vncserver`/`Xvnc`: https://tigervnc.org/doc/
- xrdp — documentación del proyecto: https://github.com/neutrinolabs/xrdp/wiki
- FreeRDP — referencia de línea de comandos: https://github.com/FreeRDP/FreeRDP/wiki/CommandLineInterface
- SPICE — protocolo y `spice-vdagent`: https://www.spice-space.org/documentation.html
- QEMU — dispositivo de display y opciones de SPICE: https://www.qemu.org/docs/master/system/invocation.html
- libvirt — Dispositivos de framebuffer gráfico en el XML del dominio: https://libvirt.org/formatdomain.html#graphical-framebuffers
- GNOME — `gnome-remote-desktop` / `grdctl`: https://gitlab.gnome.org/GNOME/gnome-remote-desktop
- GNOME — GSettings y dconf: https://help.gnome.org/admin/system-admin-guide/stable/dconf.html.en
- KDE — KConfig y `kwriteconfig`: https://develop.kde.org/docs/features/configuration/
- Xfce — documentación de Xfconf: https://docs.xfce.org/xfce/xfconf/start