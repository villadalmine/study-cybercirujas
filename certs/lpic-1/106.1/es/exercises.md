# LPIC-1 · Tema 106.1 — Instalar y configurar X11

## Ejercicios guiados

> **Requisitos del laboratorio**
>
> * Una VM Linux que puedas romper: un escritorio gráfico (GNOME/KDE/Xfce) sobre Xorg *o* Wayland, más root vía `sudo`.
> * Acceso por consola (tty2–tty6 o la consola del hipervisor). Varios pasos detienen el display manager; si tu único acceso es la GUI, te vas a dejar afuera.
> * Paquetes: `xorg-x11-server-Xorg`, `xorg-x11-apps` (o `xorg`, `x11-apps` en Debian/Ubuntu), `xorg-x11-server-Xephyr`/`xserver-xephyr`, `xorg-x11-server-Xvfb`/`xvfb`, `xorg-x11-utils`/`x11-utils`, `xauth`, `fontconfig`, `edid-decode`, `mesa-utils`/`glx-utils`.
> * Sacá un snapshot de la VM antes del Ejercicio 4. Vas a editar `/etc/X11/` y reiniciar el servidor gráfico.
>
> Objetivo de referencia: <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

## Ejercicio 1 — Identificar qué está manejando realmente tu pantalla

Antes de tocar un solo archivo de configuración, determiná si estás sobre X11, sobre Wayland, o sobre un compositor Wayland que está ejecutando clientes X a través de Xwayland. La mitad de los reportes de bugs de "configuración de X11" son sesiones Wayland donde `xorg.conf` nunca se lee.

### Pasos

1. Preguntale a la propia sesión qué protocolo usa:

   ```console
   $ echo "$XDG_SESSION_TYPE"
   wayland
   ```

2. Preguntale a `logind`, que es la fuente autoritativa (la variable de entorno puede heredarse o falsificarse):

   ```console
   $ loginctl
   SESSION  UID USER    SEAT  TTY
        2 1000 student seat0 tty2

   1 sessions listed.
   $ loginctl show-session 2 -p Type -p Class -p Active
   Type=wayland
   Class=user
   Active=yes
   ```

3. Buscá los propios procesos del servidor:

   ```console
   $ ps -eo pid,comm,args | grep -E '[X]org|[X]wayland|[g]nome-shell|[k]win|[s]way'
      1642 gnome-shell     /usr/bin/gnome-shell
      1789 Xwayland        /usr/bin/Xwayland :0 -rootless -noreset -accessx ...
   ```

4. Revisá ambos sockets de display. X11 y Wayland usan namespaces distintos:

   ```console
   $ echo "DISPLAY=$DISPLAY  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
   DISPLAY=:0  WAYLAND_DISPLAY=wayland-0
   $ ls -l /tmp/.X11-unix/ "$XDG_RUNTIME_DIR"/wayland-0
   srwxrwxrwx. 1 root root 0 Aug 26 09:11 /tmp/.X11-unix/X0
   srwxr-xr-x. 1 student student 0 Aug 26 09:11 /run/user/1000/wayland-0
   ```

5. Listá los clientes X conectados actualmente al servidor X (o a Xwayland):

   ```console
   $ xlsclients
   student-vm  xterm
   ```

6. Si tu sesión reporta `x11` en cambio, confirmá que el servidor es el Xorg real y anotá su versión:

   ```console
   $ Xorg -version 2>&1 | head -3
   X.Org X Server 21.1.13
   X Protocol Version 11, Revision 0
   Build Operating System: linux
   ```

### Comprobá tu comprensión

* **Q1.1** — Tu sesión muestra `Type=wayland` pero `DISPLAY=:0` está definida y `xterm` arranca normalmente. Explicá por qué, y nombrá el componente responsable.
* **Q1.2** — ¿Por qué `loginctl show-session ... -p Type` es más confiable que `$XDG_SESSION_TYPE`?
* **Q1.3** — En una sesión Wayland pura, ¿las ediciones a `/etc/X11/xorg.conf` van a cambiar la resolución de tu monitor? Justificá la respuesta.
* **Q1.4** — `xlsclients` no devuelve nada en un escritorio GNOME/Wayland cargado y lleno de ventanas abiertas. ¿Es una falla?

---

## Ejercicio 2 — Verificar que la placa de video y el monitor están soportados

El objetivo lo formula como "verificar que la placa de video y el monitor están soportados por un servidor X". En un stack moderno esa verificación ocurre en tres capas: el **driver DRM/KMS del kernel**, el **módulo de driver DDX de Xorg**, y el **EDID** que reporta el monitor.

### Pasos

1. Identificá el hardware gráfico y —crítico— el driver del kernel enlazado a él:

   ```console
   $ lspci -nnk | grep -EA3 'VGA|3D controller|Display controller'
   00:02.0 VGA compatible controller [0300]: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] [8086:46a6] (rev 0c)
           Subsystem: Lenovo Device [17aa:22e5]
           Kernel driver in use: i915
           Kernel modules: i915, xe
   ```

2. Confirmá que el subsistema DRM creó un nodo de card y al menos un conector:

   ```console
   $ ls /sys/class/drm/
   card1  card1-DP-1  card1-eDP-1  card1-HDMI-A-1  renderD128  version
   $ cat /sys/class/drm/card1-eDP-1/status /sys/class/drm/card1-eDP-1/enabled
   connected
   enabled
   ```

3. Revisá qué dijo el kernel al arrancar:

   ```console
   $ journalctl -b -k --grep 'drm|i915|amdgpu|nouveau' | head -8
   kernel: i915 0000:00:02.0: [drm] Found ALDERLAKE_P (device ID 46a6) integrated display version 13.00
   kernel: i915 0000:00:02.0: [drm] Finished loading DMC firmware i915/adlp_dmc.bin (v2.20)
   kernel: [drm] Initialized i915 1.6.0 for 0000:00:02.0 on minor 1
   ```

4. Listá los módulos de driver de Xorg (DDX) instalados en el sistema:

   ```console
   $ ls /usr/lib64/xorg/modules/drivers/     # Debian/Ubuntu: /usr/lib/xorg/modules/drivers/
   amdgpu_drv.so  ati_drv.so  intel_drv.so  modesetting_drv.so  nouveau_drv.so  qxl_drv.so  vmware_drv.so
   ```

5. Leé el EDID del monitor directamente desde el kernel y decodificalo:

   ```console
   $ sudo edid-decode /sys/class/drm/card1-HDMI-A-1/edid | head -12
   EDID version: 1.4
   Manufacturer: DEL Model 41142 Serial Number 1112267076
   Made in: week 31 of 2021
   Digital display
   Maximum image size: 60 cm x 34 cm
   Detailed mode: Clock 148.500 MHz, 597 mm x 336 mm
                  1920 1008 1052 1120 hborder 0
                  1080 1084 1089 1125 vborder 0
                  +hsync +vsync
                  VertRefresh: 60.000 Hz
   ```

6. Desde dentro de una sesión X en ejecución, contrastá lo que X cree sobre las salidas y los modos:

   ```console
   $ xrandr --query | head -6
   Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
   eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm
      1920x1080     60.05*+  48.00
   HDMI-1 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 597mm x 336mm
      1920x1080     60.00*+  50.00    59.94
      1680x1050     59.95
   ```

7. Confirmá que la aceleración por hardware realmente se activó (y no rendering por software `llvmpipe`):

   ```console
   $ glxinfo -B | grep -E 'OpenGL renderer|Device:'
       Device: Mesa Intel(R) Iris(R) Xe Graphics (ADL GT2) (0x46a6)
   OpenGL renderer string: Mesa Intel(R) Iris(R) Xe Graphics (ADL GT2)
   ```

### Comprobá tu comprensión

* **Q2.1** — `lspci -nnk` muestra `Kernel modules: nouveau` pero ninguna línea `Kernel driver in use:` en absoluto. ¿Cuál es la consecuencia práctica para X, y cuáles son dos causas comunes?
* **Q2.2** — ¿Qué dato del paso 5 te dice el tamaño *físico* del panel, y por qué le importa a X?
* **Q2.3** — `glxinfo -B` reporta `llvmpipe (LLVM 17.0.6, 256 bits)`. ¿X está roto? ¿Qué significa realmente este estado?
* **Q2.4** — Tu placa es una GPU AMD reciente y `/usr/lib64/xorg/modules/drivers/` no contiene ningún `amdgpu_drv.so`. ¿Puede X manejar igual la pantalla? Nombrá el módulo que se usaría.
* **Q2.5** — Un conector muestra `status: connected` en sysfs pero `disconnected` en `xrandr`. ¿Cuál es la explicación más probable en un laptop con GPU híbrida?

---

## Ejercicio 3 — Leer el log de Xorg como un diagnosticador

El log de Xorg es el artefacto más valioso de este objetivo. Sus marcadores de prefijo codifican *de dónde vino cada ajuste*, que es exactamente lo que necesitás cuando un archivo de configuración está siendo ignorado.

### Pasos

1. Localizá el log. Las distribuciones modernas ejecutan Xorg **rootless**, lo que cambia la ruta:

   ```console
   $ ls -l ~/.local/share/xorg/Xorg.0.log /var/log/Xorg.0.log 2>&1
   ls: cannot access '/var/log/Xorg.0.log': No such file or directory
   -rw-r--r--. 1 student student 41220 Aug 26 09:11 /home/student/.local/share/xorg/Xorg.0.log
   ```

2. Identificá qué fuentes de configuración usó el servidor:

   ```console
   $ grep -E 'Using config|Using system config|Loading extension|Module Loader' ~/.local/share/xorg/Xorg.0.log
   [    24.601] (==) Using config file: "/etc/X11/xorg.conf"
   [    24.601] (==) Using config directory: "/etc/X11/xorg.conf.d"
   [    24.601] (==) Using system config directory "/usr/share/X11/xorg.conf.d"
   ```

3. Extraé solamente errores y advertencias:

   ```console
   $ grep -E '\((EE|WW)\)' ~/.local/share/xorg/Xorg.0.log
   [    24.655] (WW) Warning, couldn't open module nv
   [    24.655] (EE) Failed to load module "nv" (module does not exist, 0)
   [    24.802] (WW) modeset(0): Option "Rotate" is not used
   ```

4. Estudiá la leyenda de marcadores que el propio servidor imprime en su encabezado:

   ```console
   $ sed -n '/Markers:/,/^\[.*(==) Log file/p' ~/.local/share/xorg/Xorg.0.log
   Markers: (--) probed, (**) from config file, (==) default setting,
            (++) from command line, (!!) notice, (II) informational,
            (WW) warning, (EE) error, (NI) not implemented, (??) unknown.
   ```

5. Encontrá cómo se seleccionaron el driver y la pantalla, y qué EDID parseó el servidor:

   ```console
   $ grep -E 'modeset|EDID for output|Output .* connected|Modeline' ~/.local/share/xorg/Xorg.0.log | head -8
   [    24.711] (II) modeset(0): using drv /dev/dri/card1
   [    24.780] (II) modeset(0): EDID for output HDMI-1
   [    24.780] (II) modeset(0): Manufacturer: DEL  Model: a0b6  Serial#: 1112267076
   [    24.781] (II) modeset(0): Printing probed modes for output HDMI-1
   [    24.781] (II) modeset(0): Modeline "1920x1080"x60.0  148.50  1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync (67.5 kHz eP)
   [    24.783] (II) modeset(0): Output HDMI-1 connected
   ```

6. Confirmá si el servidor está escuchando en TCP (relevante para los Ejercicios 6–8):

   ```console
   $ grep -iE 'nolisten|listen' ~/.local/share/xorg/Xorg.0.log
   [    24.602] (II) Module ABI versions:
   [    24.610] (--) Using syscons driver ...
   $ ss -ltnp 2>/dev/null | grep 600
   ```

   (Un resultado vacío es el valor por defecto esperado y seguro.)

### Comprobá tu comprensión

* **Q3.1** — Una línea dice `(**) Option "AccelMethod" "glamor"`. ¿Qué marcador es ese, y qué prueba sobre el origen del ajuste?
* **Q3.2** — Editaste `/etc/X11/xorg.conf.d/40-monitor.conf` y reiniciaste X, pero el log muestra `(==) Using default setting` para la opción que definiste. Dá dos explicaciones independientes.
* **Q3.3** — ¿Por qué desapareció `/var/log/Xorg.0.log` en las distribuciones modernas, y adónde va el log en su lugar?
* **Q3.4** — Aparece `(EE) Failed to load module "nv"` y sin embargo el escritorio arranca bien. ¿Es un error fatal? ¿Qué te dice eso sobre cómo Xorg selecciona drivers?
* **Q3.5** — ¿Qué único `grep` correrías primero en un sistema que muestra solo una pantalla negra después de `startx`, y por qué ese?

---

## Ejercicio 4 — Generar y diseccionar un `xorg.conf`

> **Paso destructivo por delante.** Sacá un snapshot de la VM. El paso 2 mata tu sesión gráfica.

### Pasos

1. Registrá el estado actual para poder volver atrás:

   ```console
   $ systemctl get-default
   graphical.target
   $ ls -l /etc/X11/xorg.conf /etc/X11/xorg.conf.d/ 2>&1
   ls: cannot access '/etc/X11/xorg.conf': No such file or directory
   total 4
   -rw-r--r--. 1 root root 168 Aug 12 18:03 00-keyboard.conf
   ```

2. Desde una consola de texto (Ctrl+Alt+F3), detené el display manager:

   ```console
   $ sudo systemctl isolate multi-user.target
   $ pgrep -a Xorg || echo "no X server running"
   no X server running
   ```

3. Hacé que el servidor sondee el hardware y escriba una plantilla de configuración:

   ```console
   $ sudo Xorg -configure
   ...
   Your xorg.conf file is /root/xorg.conf.new
   To test the server, run 'X -config /root/xorg.conf.new'
   ```

4. Inspeccioná el esqueleto generado — todas las secciones del examen LPIC-1 están acá:

   ```console
   $ sudo grep -n '^Section\|^EndSection\|Identifier\|Driver' /root/xorg.conf.new
   1:Section "ServerLayout"
   2:  Identifier     "X.org Configured"
   ...
   Section "Files"
   Section "Module"
   Section "InputDevice"   Identifier "Keyboard0"   Driver "kbd"
   Section "InputDevice"   Identifier "Mouse0"      Driver "mouse"
   Section "Monitor"       Identifier "Monitor0"
   Section "Device"        Identifier "Card0"       Driver "modesetting"
   Section "Screen"        Identifier "Screen0"
   ```

5. Leé el cableado entre secciones:

   ```console
   $ sudo sed -n '/Section "ServerLayout"/,/EndSection/p;/Section "Screen"/,/EndSection/p' /root/xorg.conf.new
   Section "ServerLayout"
       Identifier     "X.org Configured"
       Screen      0  "Screen0" 0 0
       InputDevice    "Mouse0" "CorePointer"
       InputDevice    "Keyboard0" "CoreKeyboard"
   EndSection

   Section "Screen"
       Identifier "Screen0"
       Device     "Card0"
       Monitor    "Monitor0"
       SubSection "Display"
           Viewport   0 0
           Depth     24
       EndSubSection
   EndSection
   ```

6. Probá el archivo en un **número de display libre**, sin instalarlo:

   ```console
   $ sudo X -config /root/xorg.conf.new -retro :1 &
   $ DISPLAY=:1 xdpyinfo | head -5
   name of display:    :1
   version number:    11.0
   vendor string:    The X.Org Foundation
   vendor release number:    12101013
   X.Org version: 21.1.13
   $ sudo pkill -f 'X -config'
   ```

7. Devolvé la máquina a la normalidad:

   ```console
   $ sudo systemctl isolate graphical.target
   ```

### Comprobá tu comprensión

* **Q4.1** — ¿Cuál sección es la raíz del árbol de configuración, y qué dos tipos de sección referencia?
* **Q4.2** — Dá la cadena de referencias desde `ServerLayout` hasta el monitor físico, nombrando cada sección.
* **Q4.3** — ¿Por qué `Xorg -configure` se niega a correr mientras tu sesión de escritorio está activa, y por qué debe correr como root?
* **Q4.4** — ¿Dónde escribe `Xorg -configure` su salida, y por qué esa ruta *no* es donde X la va a buscar?
* **Q4.5** — ¿Qué hace `-retro`, y por qué es útil exactamente en esta prueba?
* **Q4.6** — En un sistema actual, `Xorg -configure` falla con `Number of created screens does not match number of detected devices`. ¿Significa eso que el hardware no está soportado?

---

## Ejercicio 5 — Configuración modular con `/etc/X11/xorg.conf.d/`

Los archivos `xorg.conf` monolíticos son legacy. El enfoque soportado son fragmentos pequeños, cada uno dueño de una sola preocupación, fusionados al arrancar el servidor.

### Pasos

1. Mirá lo que el proveedor ya trae (nunca edites esto; pertenece a los paquetes):

   ```console
   $ ls /usr/share/X11/xorg.conf.d/
   10-quirks.conf  40-libinput.conf  70-wacom.conf
   ```

2. Creá un fragmento propio del administrador que fuerce una distribución de teclado:

   ```console
   $ sudo tee /etc/X11/xorg.conf.d/00-keyboard.conf >/dev/null <<'EOF'
   Section "InputClass"
       Identifier "system-keyboard"
       MatchIsKeyboard "on"
       Option "XkbLayout" "es,us"
       Option "XkbVariant" ","
       Option "XkbOptions" "grp:alt_shift_toggle,terminate:ctrl_alt_bksp"
   EndSection
   EOF
   ```

3. Agregá un fragmento de puntero usando matching de `InputClass` en vez de un `InputDevice` estático:

   ```console
   $ sudo tee /etc/X11/xorg.conf.d/50-touchpad.conf >/dev/null <<'EOF'
   Section "InputClass"
       Identifier "touchpad-tuning"
       MatchIsTouchpad "on"
       MatchDriver "libinput"
       Option "Tapping" "on"
       Option "NaturalScrolling" "true"
       Option "ClickMethod" "clickfinger"
   EndSection
   EOF
   ```

4. Agregá un fragmento `Monitor` que fije un modo preferido y una posición:

   ```console
   $ sudo tee /etc/X11/xorg.conf.d/40-monitor.conf >/dev/null <<'EOF'
   Section "Monitor"
       Identifier "HDMI-1"
       Option "PreferredMode" "1920x1080"
       Option "Position" "1920 0"
       Option "DPMS" "true"
   EndSection
   EOF
   ```

5. Validá la sintaxis *antes* de reiniciar la sesión, en un display libre:

   ```console
   $ sudo systemctl isolate multi-user.target
   $ sudo X :1 -verbose 3 -logfile /tmp/Xtest.log ; echo "exit=$?"
   exit=1
   $ grep -E '\((EE|WW)\)' /tmp/Xtest.log
   [   12.004] (WW) The directory "/usr/share/fonts/X11/cyrillic" does not exist.
   ```

6. Confirmá el orden de fusión y qué fragmento ganó:

   ```console
   $ grep -E 'Using config directory|Parsing|InputClass' /tmp/Xtest.log | head
   [   11.960] (==) Using config directory: "/etc/X11/xorg.conf.d"
   [   11.960] (==) Using system config directory "/usr/share/X11/xorg.conf.d"
   [   12.110] (II) Using input driver 'libinput' for 'SynPS/2 Synaptics TouchPad'
   [   12.111] (**) Option "Tapping" "on"
   ```

7. Verificá la configuración de teclado en vivo una vez que el escritorio volvió:

   ```console
   $ setxkbmap -query
   rules:      evdev
   model:      pc105
   layout:     es,us
   options:    grp:alt_shift_toggle,terminate:ctrl_alt_bksp
   ```

### Comprobá tu comprensión

* **Q5.1** — ¿En qué orden se leen los archivos de `/etc/X11/xorg.conf.d/`, y por qué los nombres que vienen con el sistema empiezan con dos dígitos?
* **Q5.2** — Dos fragmentos, `10-touchpad.conf` y `90-touchpad.conf`, definen ambos `Option "Tapping"` con valores distintos sobre el mismo dispositivo. ¿Qué valor se aplica?
* **Q5.3** — ¿Cuál es la diferencia funcional entre una sección `InputDevice` y una sección `InputClass`? ¿Por qué X moderno se pasó a la segunda?
* **Q5.4** — Si `/etc/X11/xorg.conf` existe *y* `/etc/X11/xorg.conf.d/` contiene fragmentos, ¿cuál se usa?
* **Q5.5** — ¿Por qué editar archivos bajo `/usr/share/X11/xorg.conf.d/` es una mala costumbre incluso cuando funciona?
* **Q5.6** — En el paso 5, `X :1` salió con estado 1 y solo advertencias en el log. ¿Cuál es la razón benigna más probable, y cómo se vería distinto un error de sintaxis *real*?

---

## Ejercicio 6 — La variable `DISPLAY`, números de display y servidores anidados

`Xephyr` y `Xvfb` te dejan practicar todo el modelo `DISPLAY`/`xauth` de forma segura, sin tocar la sesión en la que estás sentado — y funcionan en un servidor headless.

### Pasos

1. Inspeccioná el valor actual y descomponelo:

   ```console
   $ echo "$DISPLAY"
   :0
   $ xdpyinfo | grep -E 'name of display|number of screens|dimensions'
   name of display:    :0
   number of screens:    1
     dimensions:    1920x1080 pixels (508x285 millimeters)
   ```

2. Arrancá un servidor X **anidado** dentro de tu escritorio actual:

   ```console
   $ Xephyr :3 -screen 1280x800 -title "LPIC lab display :3" &
   [1] 8123
   $ ls -l /tmp/.X11-unix/
   srwxrwxrwx. 1 root    root    0 Aug 26 09:11 X0
   srwxrwxrwx. 1 student student 0 Aug 26 10:44 X3
   ```

3. Apuntá un cliente hacia él de dos maneras distintas — por comando y por shell:

   ```console
   $ DISPLAY=:3 xterm -geometry 80x24 &
   $ export DISPLAY=:3
   $ xclock -update 1 &
   $ xlsclients -display :3
   student-vm  xterm
   student-vm  xclock
   ```

4. Demostrá que número de display y número de screen son cosas distintas:

   ```console
   $ DISPLAY=:3.0 xdpyinfo | grep 'name of display'
   name of display:    :3.0
   $ DISPLAY=:3.7 xdpyinfo
   X connection to :3.7 broken (explicit kill or server shutdown).
   ```

5. Arrancá un framebuffer virtual **headless** — la herramienta estándar para CI y pruebas remotas:

   ```console
   $ Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp &
   $ DISPLAY=:99 xdpyinfo | grep -E 'dimensions|depth of root'
     dimensions:    1280x1024 pixels (325x270 millimeters)
     depth of root window:    24 planes
   $ DISPLAY=:99 xterm & sleep 2 ; DISPLAY=:99 xwd -root -out /tmp/shot.xwd
   ```

6. Observá los modos de falla que produce un `DISPLAY` no definido o incorrecto:

   ```console
   $ unset DISPLAY ; xclock
   Error: Can't open display:
   $ DISPLAY=:42 xclock
   Error: Can't open display: :42
   $ DISPLAY=remote.example.com:0 xclock
   xclock: Error: Can't open display: remote.example.com:0
   ```

7. Limpiá:

   ```console
   $ export DISPLAY=:0
   $ pkill Xephyr ; pkill Xvfb
   ```

### Comprobá tu comprensión

* **Q6.1** — Descomponé `DISPLAY=srv1.example.com:2.1` en sus tres componentes e indicá qué selecciona cada uno.
* **Q6.2** — ¿Qué transporte usa `DISPLAY=:0` frente a `DISPLAY=localhost:0`? ¿Qué archivo o socket toca cada uno?
* **Q6.3** — ¿Qué puerto TCP corresponde al número de display `4`? Dá la fórmula.
* **Q6.4** — Explicá, en el modelo cliente/servidor de X, qué máquina ejecuta el *servidor* cuando mostrás un programa remoto en tu laptop.
* **Q6.5** — ¿Por qué `Xvfb` es la herramienta correcta para pruebas automatizadas de capturas de pantalla en un servidor sin GPU, y qué significa `1280x1024x24`?
* **Q6.6** — Un trabajo de cron ejecuta `xrandr` y falla con `Can't open display`. Nombrá las dos variables de entorno que tenés que arreglar, y por qué definir solo una no alcanza.

---

## Ejercicio 7 — Control de acceso: `xhost` y `xauth`

X tiene dos capas de autorización independientes. `xhost` se basa en host/usuario y es gruesa; `xauth` se basa en cookies y es lo que realmente protege un escritorio moderno.

### Pasos

1. Inspeccioná la lista basada en hosts:

   ```console
   $ xhost
   access control enabled, only authorized clients can connect
   SI:localuser:student
   SI:localuser:gdm
   ```

2. Inspeccioná la capa basada en cookies:

   ```console
   $ echo "$XAUTHORITY"
   /run/user/1000/.mutter-Xwaylandauth.QK2R41
   $ xauth list
   student-vm/unix:0  MIT-MAGIC-COOKIE-1  9f2a4b0c7e18d3a65b4c9f1e2d7a8b30
   $ xauth info
   Authority file:       /run/user/1000/.mutter-Xwaylandauth.QK2R41
   File new:             no
   File locked:          no
   Number of entries:    2
   Changes honored:      yes
   ```

3. Demostrá la falla con la que se topa un segundo usuario (creá el usuario si hace falta):

   ```console
   $ sudo useradd -m tester
   $ sudo -u tester env DISPLAY=:0 xclock
   No protocol specified
   Error: Can't open display: :0
   ```

4. Otorgá acceso *correctamente* — con una cookie, no abriendo el servidor:

   ```console
   $ xauth extract - "$DISPLAY" | sudo -u tester env XAUTHORITY=/home/tester/.Xauthority xauth merge -
   $ sudo -u tester env DISPLAY=:0 XAUTHORITY=/home/tester/.Xauthority xclock &
   ```

5. Comparalo con la alternativa gruesa, y después deshacelo de inmediato:

   ```console
   $ xhost +SI:localuser:tester
   localuser:tester being added to access control list
   $ xhost
   access control enabled, only authorized clients can connect
   SI:localuser:tester
   SI:localuser:student
   $ xhost -SI:localuser:tester
   localuser:tester being removed from access control list
   ```

6. Observá — **solo en el display Xephyr descartable** — cómo se ve desactivar el control de acceso:

   ```console
   $ Xephyr :3 -screen 800x600 &
   $ DISPLAY=:3 xhost +
   access control disabled, clients can connect from any host
   $ DISPLAY=:3 xhost
   access control disabled, clients can connect from any host
   $ DISPLAY=:3 xhost -
   access control enabled, only authorized clients can connect
   $ pkill Xephyr
   ```

7. Inspeccioná un archivo de cookies que pertenece al display manager, para ver dónde viven realmente las cookies bajo GDM/SDDM:

   ```console
   $ sudo xauth -f /run/user/1000/gdm/Xauthority list 2>/dev/null || echo "path varies by display manager"
   student-vm/unix:0  MIT-MAGIC-COOKIE-1  c1d5e8a94b3f27061a8e5d2c9b4f7a13
   ```

### Comprobá tu comprensión

* **Q7.1** — ¿Qué hace exactamente `xhost +`, y por qué se considera un compromiso total de la sesión y no una comodidad? Nombrá dos ataques concretos que habilita.
* **Q7.2** — ¿Qué protocolo de autorización reporta `xauth list`, y dónde se almacena la cookie por defecto?
* **Q7.3** — `xauth` es una herramienta del lado cliente que edita un archivo. ¿Cómo se entera alguna vez el servidor X de una cookie que fusionaste?
* **Q7.4** — Distinguí `No protocol specified` de `Client is not authorized to connect to Server`. ¿Qué implica cada uno?
* **Q7.5** — Root ejecuta `xclock` en el `:0` del usuario y falla. ¿Por qué ser root no ayuda, y cuál es el arreglo correcto?
* **Q7.6** — `$XAUTHORITY` apunta a `/run/user/1000/.mutter-Xwaylandauth.XXXXXX` en vez de `~/.Xauthority`. Explicá por qué, e indicá la consecuencia para un script que hardcodea `~/.Xauthority`.

---

## Ejercicio 8 — Display remoto: reenvío X11 por SSH vs. TCP crudo

### Pasos

1. Confirmá que el servidor local **no** está escuchando en TCP (el valor por defecto desde X.Org 1.17):

   ```console
   $ ss -ltn '( sport = :6000 )' ; pgrep -a Xorg | grep -o 'nolisten tcp' || echo "check Xorg args"
   State  Recv-Q Send-Q Local Address:Port Peer Address:Port
   ```

2. Habilitá el reenvío en el host **remoto**:

   ```console
   $ sudo grep -E '^\s*X11(Forwarding|DisplayOffset|UseLocalhost)' /etc/ssh/sshd_config
   X11Forwarding yes
   X11DisplayOffset 10
   X11UseLocalhost yes
   $ sudo systemctl reload sshd
   $ rpm -q xorg-x11-xauth || dpkg -l xauth   # xauth MUST exist on the remote host
   ```

3. Conectate con reenvío **untrusted** e inspeccioná lo que SSH te armó:

   ```console
   $ ssh -X student@server1
   student@server1:~$ echo "$DISPLAY"
   localhost:10.0
   student@server1:~$ xauth list
   server1/unix:10  MIT-MAGIC-COOKIE-1  4b7e1a92c8d305f6...
   student@server1:~$ ss -ltn | grep 6010
   LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*
   student@server1:~$ xclock &
   ```

4. Observá las restricciones del modo untrusted:

   ```console
   student@server1:~$ xdpyinfo | grep -c 'X-Resource\|SECURITY'
   1
   student@server1:~$ xwd -root -out /tmp/x.xwd
   X Error of failed request:  BadWindow (invalid Window parameter)
   ```

5. Reintentá con reenvío **trusted** y compará:

   ```console
   $ ssh -Y student@server1 'DISPLAY=localhost:10.0 xwd -root -out /tmp/x.xwd && echo captured'
   captured
   ```

6. Mirá cómo expira una sesión reenviada (las cookies untrusted caducan; el `ForwardX11Timeout` por defecto es 20 minutos):

   ```console
   $ ssh -o ForwardX11Timeout=30 -X student@server1
   student@server1:~$ sleep 45 ; xclock
   X11 connection rejected because of wrong authentication.
   Error: Can't open display: localhost:10.0
   ```

7. Solo para contraste — **no** dejes esto habilitado — mirá qué requeriría TCP crudo:

   ```console
   # Would need: Xorg started with '-listen tcp', firewall open on 6000/tcp,
   # and either xhost + (insecure) or a cookie copied to the remote host.
   $ grep -rn 'nolisten' /usr/lib/systemd/system/display-manager.service /etc/gdm/custom.conf 2>/dev/null
   ```

### Comprobá tu comprensión

* **Q8.1** — ¿Por qué `DISPLAY=localhost:10.0` en vez de `laptop:0` dentro de una sesión SSH? ¿Para qué sirve `X11DisplayOffset`?
* **Q8.2** — Indicá la diferencia entre `ssh -X` y `ssh -Y` en términos de la extensión SECURITY de X, y cuándo corresponde cada uno.
* **Q8.3** — El reenvío X11 falla con `X11 forwarding request failed on channel 0`, y `$DISPLAY` está vacío en el host remoto. Dá tres verificaciones, en orden.
* **Q8.4** — Con `X11UseLocalhost yes`, el puerto 6010 se enlaza a `127.0.0.1`. ¿Qué se rompe si necesitás que un *contenedor* en el host remoto use ese display, y cuál es el ajuste?
* **Q8.5** — ¿Por qué se prefiere el reenvío por SSH antes que `xhost +` más `-listen tcp`, incluso dentro de una LAN confiable? Mencioná confidencialidad y autenticación por separado.
* **Q8.6** — Una GUI de larga duración sobre `ssh -X` muere después de ~20 minutos con un error de autenticación. Nombrá la causa y dos arreglos.

---

## Ejercicio 9 — Fuentes: el servidor de fuentes de X y su reemplazo moderno

El objetivo pide *conocimiento del servidor de fuentes de X*. En la práctica tenés que conocer los dos modelos: la ruta legacy de **fuentes core de X** (del lado del servidor, `xfs`, `FontPath`) y **fontconfig** (del lado del cliente, `fc-*`), que es lo que realmente usa todo toolkit moderno.

### Pasos

1. Consultá el font path core del servidor:

   ```console
   $ xset q | sed -n '/Font Path/,+2p'
   Font Path:
     catalogue:/etc/X11/fontpath.d,built-ins
   ```

2. Listá las fuentes core que el servidor puede servir, y probá un XLFD legacy:

   ```console
   $ xlsfonts | head -5
   -misc-fixed-medium-r-normal--13-120-75-75-c-70-iso8859-1
   builtins
   cursor
   fixed
   $ xlsfonts | wc -l
   17
   $ xfd -fn fixed &
   ```

3. Construí un directorio de fuentes core a mano — este es el mecanismo que consume `FontPath`:

   ```console
   $ mkdir -p ~/lab-fonts && cp /usr/share/fonts/liberation-mono/*.ttf ~/lab-fonts/ 2>/dev/null
   $ cd ~/lab-fonts && mkfontscale . && mkfontdir .
   $ head -3 fonts.dir
   4
   LiberationMono-Regular.ttf -1-liberation mono-medium-r-normal--0-0-0-0-m-0-iso10646-1
   ```

4. Agregalo al font path del servidor en ejecución, y después quitalo:

   ```console
   $ xset +fp ~/lab-fonts
   $ xset fp rehash
   $ xset q | sed -n '/Font Path/,+2p'
   Font Path:
     /home/student/lab-fonts,catalogue:/etc/X11/fontpath.d,built-ins
   $ xset -fp ~/lab-fonts
   ```

5. Inspeccioná la configuración del servidor de fuentes legacy si `xfs` está presente (muchas distribuciones ya no lo incluyen):

   ```console
   $ systemctl status xfs 2>&1 | head -3
   Unit xfs.service could not be found.
   $ ls /etc/X11/fs/config 2>&1
   ls: cannot access '/etc/X11/fs/config': No such file or directory
   ```

   Un despliegue histórico de `xfs` se veía así: el demonio escuchaba en **TCP 7100**, `/etc/X11/fs/config` definía `catalogue = ...` y `port = 7100`, y a los clientes se los apuntaba a él con `FontPath "tcp/fontsrv.example.com:7100"` o `FontPath "unix/:7100"` en la sección `Files` de `xorg.conf`.

6. Ahora trabajá con el mecanismo que realmente está en uso hoy:

   ```console
   $ fc-list | wc -l
   612
   $ fc-list : family | sort -u | head -5
   Cantarell
   DejaVu Sans
   DejaVu Sans Mono
   Liberation Mono
   Liberation Sans
   $ fc-match monospace
   DejaVuSansMono.ttf: "DejaVu Sans Mono" "Book"
   $ fc-match "Helvetica"
   LiberationSans-Regular.ttf: "Liberation Sans" "Regular"
   ```

7. Instalá una fuente para un solo usuario y refrescá la caché:

   ```console
   $ mkdir -p ~/.local/share/fonts && cp ~/lab-fonts/*.ttf ~/.local/share/fonts/
   $ fc-cache -fv ~/.local/share/fonts | tail -2
   /home/student/.local/share/fonts: caching, new cache contents: 4 fonts, 0 dirs
   fc-cache: succeeded
   $ fc-list | grep -c "$HOME/.local/share/fonts"
   4
   ```

### Comprobá tu comprensión

* **Q9.1** — Explicá la diferencia arquitectónica entre las fuentes core de X y fontconfig: ¿qué proceso abre el archivo de fuente en cada modelo?
* **Q9.2** — ¿Para qué servía `xfs`, en qué puerto escuchaba, y qué lo volvió obsoleto?
* **Q9.3** — ¿En qué sección de `xorg.conf` va `FontPath`, y dá un valor válido que apunte a un servidor de fuentes?
* **Q9.4** — `xlsfonts` muestra 17 fuentes mientras que `fc-list` muestra 612. Explicá la discrepancia sin concluir que algo está roto.
* **Q9.5** — ¿Qué producen `mkfontscale` y `mkfontdir`, y por qué existe `xset fp rehash`?
* **Q9.6** — Un usuario deja un `.ttf` en `~/.local/share/fonts` y la fuente no aparece en su editor. ¿Cuál es el comando faltante, y por qué normalmente no hace falta cerrar sesión?

---

## Ejercicio 10 — Diagnosticar un arranque de X roto (`~/.xsession-errors` y el journal)

### Pasos

1. Rompé la configuración deliberadamente, con un driver que no existe:

   ```console
   $ sudo tee /etc/X11/xorg.conf.d/99-broken.conf >/dev/null <<'EOF'
   Section "Device"
       Identifier "Card0"
       Driver     "sisusb"
       Option     "NoAccel" "true"
   EndSection
   EOF
   ```

2. Intentá un arranque en un display libre desde una consola de texto y capturá la falla:

   ```console
   $ sudo systemctl isolate multi-user.target
   $ X :1 -logfile /tmp/Xbroken.log ; echo "exit=$?"
   exit=1
   $ grep -E '\(EE\)' /tmp/Xbroken.log
   (EE) Failed to load module "sisusb" (module does not exist, 0)
   (EE) No drivers available.
   (EE) Fatal server error:
   (EE) no screens found(EE)
   ```

3. Leé el bloque de resumen del propio log, que nombra el archivo a enviar en un reporte de bug:

   ```console
   $ tail -6 /tmp/Xbroken.log
   (EE)
   Please consult the The X.Org Foundation support at http://wiki.x.org
   for help.
   (EE) Please also check the log file at "/tmp/Xbroken.log" for additional information.
   (EE)
   (EE) Server terminated with error (1). Closing log file.
   ```

4. Inspeccioná el archivo de errores a nivel de sesión, que captura fallas de *clientes* y no del servidor:

   ```console
   $ ls -l ~/.xsession-errors 2>/dev/null && tail -5 ~/.xsession-errors
   -rw-------. 1 student student 3120 Aug 26 09:12 /home/student/.xsession-errors
   openConnection: connect: No such file or directory
   cannot connect to brltty at :0
   gnome-session-binary[1602]: WARNING: Failed to start app: xdg-desktop-portal
   ```

5. En escritorios basados en systemd, leé el equivalente desde el journal:

   ```console
   $ journalctl --user -b -u gnome-session-manager --no-pager | tail -5
   $ journalctl -b _COMM=gdm-x-session --no-pager | tail -5
   gdm-x-session[1521]: (EE) Fatal server error:
   gdm-x-session[1521]: (EE) no screens found(EE)
   ```

6. Reparalo y confirmá:

   ```console
   $ sudo rm /etc/X11/xorg.conf.d/99-broken.conf
   $ X :1 -logfile /tmp/Xok.log & sleep 2 ; DISPLAY=:1 xdpyinfo | head -2 ; pkill -f 'X :1'
   name of display:    :1
   version number:    11.0
   $ sudo systemctl isolate graphical.target
   ```

7. Practicá la vía de recuperación de emergencia que usarías por SSH en una máquina headless por accidente:

   ```console
   $ sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.disabled   # let X autodetect
   $ sudo systemctl set-default multi-user.target             # boot to text next time
   $ sudo systemctl isolate graphical.target                  # test without rebooting
   ```

### Comprobá tu comprensión

* **Q10.1** — ¿Cuál es la diferencia de alcance entre `/var/log/Xorg.0.log` (o `~/.local/share/xorg/Xorg.0.log`) y `~/.xsession-errors`?
* **Q10.2** — `no screens found` es el síntoma. Nombrá tres causas raíz distintas que lo producen.
* **Q10.3** — Tu único acceso es SSH y la máquina arranca a una pantalla gráfica negra. Dá la recuperación de dos comandos que garantiza un login de texto usable en el próximo arranque.
* **Q10.4** — ¿Por qué `X :1 -logfile /tmp/x.log` es más seguro para probar que reiniciar el display manager?
* **Q10.5** — `~/.xsession-errors` no existe en absoluto en un sistema GNOME/Wayland. ¿Adónde van los errores de los clientes, y con qué comando los leés?
* **Q10.6** — El archivo `~/.xsession-errors` creció a 4 GB. ¿Qué suele indicar eso, y por qué puede llenar `/home`?

---

## Ejercicio 11 — Conocimiento de Wayland y Xwayland

### Pasos

1. Iniciá sesión en una sesión Wayland y enumerá la vista del compositor:

   ```console
   $ wayland-info | head -12       # package: wayland-utils
   interface: 'wl_compositor',                              version:  6, name:  1
   interface: 'wl_shm',                                     version:  2, name:  2
   interface: 'wl_output',                                  version:  4, name:  8
       x: 0, y: 0, scale: 1,
       physical_width: 344 mm, physical_height: 194 mm,
       mode: 1920 × 1080 @ 60.052 Hz (current, preferred)
   interface: 'xdg_wm_base',                                version:  6, name: 12
   ```

2. Confirmá que Xwayland está presente y mirá quién es dueño del socket X:

   ```console
   $ pgrep -a Xwayland
   1789 /usr/bin/Xwayland :0 -rootless -noreset -accessx -core -auth /run/user/1000/.mutter-Xwaylandauth.QK2R41 -listenfd 4
   $ xdpyinfo | grep -E 'vendor string|name of display'
   name of display:    :0
   vendor string:    The X.Org Foundation
   ```

3. Ejecutá un cliente X legacy y confirmá que pasa por Xwayland:

   ```console
   $ xeyes &
   $ xlsclients
   student-vm  xeyes
   ```

4. Observá qué puede y qué no puede hacer el instrumental de X bajo Wayland:

   ```console
   $ xrandr --output eDP-1 --mode 1280x720
   xrandr: Configure crtc 0 failed
   $ xdotool search --name "Firefox"
   $ xhost +SI:localuser:tester      # affects only Xwayland clients
   localuser:tester being added to access control list
   ```

5. Comparé quién es dueño del escalado por aplicación:

   ```console
   $ gnome-randr 2>/dev/null || echo "use the compositor's own tool / Settings → Displays"
   $ echo "GDK_BACKEND=$GDK_BACKEND QT_QPA_PLATFORM=$QT_QPA_PLATFORM"
   GDK_BACKEND= QT_QPA_PLATFORM=
   $ GDK_BACKEND=x11 gedit &   # forces a GTK app through Xwayland
   ```

6. Volvé una sesión a X11 para comparar comportamiento (GDM):

   ```console
   $ sudo grep -n 'WaylandEnable' /etc/gdm/custom.conf
   #WaylandEnable=false
   $ sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm/custom.conf
   $ sudo systemctl restart gdm      # logs you out
   $ echo "$XDG_SESSION_TYPE"
   x11
   ```

### Comprobá tu comprensión

* **Q11.1** — En una oración cada uno, indicá la diferencia arquitectónica entre X11 y Wayland respecto del servidor gráfico, el window manager y el compositor.
* **Q11.2** — ¿Qué es Xwayland, y por qué `DISPLAY` sigue definida en una sesión Wayland?
* **Q11.3** — `xrandr --output ... --mode ...` falla bajo Wayland. ¿Por qué, y qué lo reemplaza?
* **Q11.4** — ¿Por qué `xdotool search` no encuentra nada para ventanas Wayland nativas, y por qué eso es una propiedad de seguridad deliberada y no un bug?
* **Q11.5** — Una herramienta de grabación de pantalla "funcionaba en X11" y muestra un cuadro negro en Wayland. Nombrá el mecanismo que debe usar en su lugar.
* **Q11.6** — Bajo Wayland, ¿`xhost +` sigue creando un riesgo? Delimitá tu respuesta con precisión.

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 1

**A1.1** — El compositor lanzó **Xwayland**, un servidor X rootless que traduce el protocolo X11 a superficies Wayland. Es dueño del display `:0` y del socket `/tmp/.X11-unix/X0`, así que `DISPLAY=:0` es válido y los clientes X legacy siguen funcionando. El tipo de sesión sigue siendo `wayland`; no hay proceso Xorg.

**A1.2** — `$XDG_SESSION_TYPE` es una variable de entorno común: la heredan los procesos hijos, sobrevive a `su`, puede quedar obsoleta dentro de `tmux`/`screen`/cron, y simplemente puede exportarse a mano. `loginctl` lee el registro de sesión que `systemd-logind` creó al iniciar sesión, que refleja lo que el display manager realmente arrancó.

**A1.3** — No. `xorg.conf` y `xorg.conf.d/` los parsea **únicamente el servidor Xorg**. Un compositor Wayland (mutter, KWin, sway) tiene su propia configuración y nunca los lee. Xwayland mismo acepta flags de línea de comandos desde el compositor, no un `xorg.conf`. El mode setting bajo Wayland lo hace el compositor vía DRM/KMS.

**A1.4** — No. `xlsclients` enumera clientes conectados al **servidor X**. En Wayland, los clientes nativos (aplicaciones GNOME, Firefox en modo Wayland) se conectan al compositor, no a Xwayland, así que le son invisibles. Una salida vacía significa "ningún cliente X11 en este momento", no "ninguna ventana".

---

### Ejercicio 2

**A2.1** — No hay driver del kernel enlazado, así que no hay dispositivo KMS `/dev/dri/cardN`. El DDX `modesetting` no tiene nada que manejar y X cae a `fbdev`/`vesa` o falla con `no screens found`. Causas comunes: (a) el módulo está en lista negra — típicamente `nouveau` bloqueado por una instalación propietaria de NVIDIA; revisá `/etc/modprobe.d/` y la línea de comandos del kernel buscando `nomodeset`/`modprobe.blacklist=`; (b) el módulo falta en el kernel/initramfs instalado, o el firmware no cargó (`journalctl -b -k | grep -i firmware`).

**A2.2** — `Maximum image size: 60 cm x 34 cm` y el `597 mm x 336 mm` por modo. X usa las dimensiones físicas junto con la resolución para calcular el **DPI**, que rige el escalado de fuentes y de la interfaz. Un monitor que reporta un tamaño físico erróneo o ausente es la causa clásica de fuentes cómicamente grandes o diminutas; podés sobrescribirlo con `xrandr --dpi` o con una entrada `DisplaySize` en una sección `Monitor`.

**A2.3** — X está funcionando, pero **sin aceleración por hardware**: `llvmpipe` es el rasterizador por CPU de Mesa. Todo se renderiza correctamente y lento, el video y la composición se entrecortan. Señala un driver DRM faltante o incorrecto, un paquete de driver Mesa faltante, un problema de whitelist de GPU, o una VM sin aceleración 3D habilitada.

**A2.4** — Sí. El DDX genérico **`modesetting_drv.so`** maneja cualquier GPU que tenga un driver KMS del kernel, usando glamor sobre OpenGL para la aceleración. Los drivers DDX dedicados `amdgpu`/`intel` son optimizaciones opcionales; varias distribuciones incluyen deliberadamente solo `modesetting`.

**A2.5** — El conector pertenece a una GPU distinta de la que X está manejando — típicamente la GPU discreta en un laptop híbrido (Optimus/PRIME), donde el puerto externo está cableado a la dGPU mientras X corre sobre la integrada. `xrandr --listproviders` y el offloading de salidas PRIME (`xrandr --setprovideroutputsource`) son las herramientas; sysfs ve todas las placas, X ve solo las screens que configuró.

---

### Ejercicio 3

**A3.1** — `(**)` significa **"desde archivo de configuración"**. Prueba que el valor vino de `xorg.conf` o de un fragmento en un directorio de configuración, no del sondeo (`--`), no de un valor por defecto compilado (`==`), y no de la línea de comandos (`++`). Esta sola distinción resuelve la mayoría de los reportes de "mi configuración está siendo ignorada".

**A3.2** — (1) El fragmento no se está leyendo: directorio equivocado, extensión equivocada (debe ser `.conf`), permisos ilegibles, o sobrescrito por un archivo que ordena después. Verificalo con las líneas `(==) Using config directory` y buscando el nombre de la opción con grep. (2) La sección no coincide: un `InputClass` cuyas directivas `Match*` nunca coinciden con el dispositivo, o un `Identifier` de `Monitor` que no corresponde al nombre real de la salida (`HDMI-1` vs `HDMI-A-1`). Una tercera posibilidad: la sesión es Wayland, así que no se lee nada en absoluto.

**A3.3** — Xorg ya no se instala setuid-root en la mayoría de las distribuciones; corre como el usuario que inició sesión, vía `systemd-logind` (X rootless). Un proceso sin privilegios no puede escribir en `/var/log`, así que el log va a **`~/.local/share/xorg/Xorg.<display>.log`**. Cuando X *sí* se arranca como root (`startx` como root, o una compilación setuid) se sigue usando la ruta vieja.

**A3.4** — No es fatal. `(EE)` marca una condición de error, no necesariamente fatal; solo `Fatal server error` termina el servidor. Xorg prueba una lista de drivers candidatos — desde `xorg.conf`, después autodetección, después fallbacks genéricos — y un candidato fallido se registra y se saltea. Una línea obsoleta `Driver "nv"` en un `xorg.conf` viejo produce exactamente esto.

**A3.5** — `grep -E '\(EE\)' <logfile>`. Los errores son la única clase que puede abortar el servidor, y el bloque de error fatal al final del log nombra tanto la causa (`no screens found`, `Cannot run in framebuffer mode`, `parse error`) como la ruta del log. Las advertencias son casi siempre ruido (directorios de fuentes faltantes, opciones no usadas).

---

### Ejercicio 4

**A4.1** — **`ServerLayout`** es la raíz. Referencia secciones **`Screen`** (con su posición en el escritorio virtual) y secciones **`InputDevice`** (`CorePointer`, `CoreKeyboard`). Si existen varias secciones `ServerLayout`, se usa la primera salvo que `-layout` seleccione otra.

**A4.2** — `ServerLayout` → `Screen` → (`Device` **y** `Monitor`). El `Screen` vincula un `Device` de gráficos (el driver/placa) con un `Monitor` (los rangos de sincronismo, modos y tamaño físico de la salida) y define profundidad/resolución en sus subsecciones `Display`.

**A4.3** — `Xorg -configure` arranca un servidor temporal para sondear el hardware; no puede hacerlo mientras otro servidor ya tiene la VT y el lease de DRM master. Se requiere root porque el sondeo abre recursos PCI y nodos de dispositivo `/dev/dri/*` directamente, y porque escribe en `/root`.

**A4.4** — Escribe **`/root/xorg.conf.new`** (en el home del invocante; históricamente el directorio actual). X nunca lee esa ruta. El archivo es una plantilla para revisar, probar con `X -config`, y recién entonces instalar como `/etc/X11/xorg.conf` — deliberadamente, para que un sondeo malo no pueda romper el siguiente arranque.

**A4.5** — `-retro` dibuja el clásico patrón de trama en blanco y negro de la ventana raíz con un cursor X en vez de una raíz negra lisa. En un display de prueba distingue "el servidor arrancó y está corriendo sin clientes" de "el servidor murió / la pantalla está genuinamente en blanco".

**A4.6** — No. Es una limitación conocida de `-configure` con drivers KMS: el sondeo enumera dispositivos de forma distinta a cómo el servidor crea screens. La conclusión moderna correcta es que un `xorg.conf` estático es innecesario — la autodetección a través de `modesetting` funciona — y cualquier ajuste necesario va en un pequeño fragmento en `xorg.conf.d`.

---

### Ejercicio 5

**A5.1** — En **orden lexicográfico (ASCII)** dentro de cada directorio. El directorio del proveedor `/usr/share/X11/xorg.conf.d` se lee antes que el directorio del administrador `/etc/X11/xorg.conf.d`; el log registra ambos con `(==) Using config directory` / `Using system config directory`. Los prefijos numéricos hacen ese orden explícito y controlable — `10-` carga antes que `50-` y que `90-`.

**A5.2** — El valor de **`90-touchpad.conf`**. Para `InputClass`, las secciones coincidentes posteriores se aplican encima de las anteriores, así que gana la última asignación coincidente de una opción dada.

**A5.3** — `InputDevice` declara estáticamente un dispositivo y debe ser referenciado desde `ServerLayout`; hardcodea una ruta de dispositivo. `InputClass` declara *reglas* que coinciden con dispositivos dinámicamente al momento del hotplug vía `MatchIsPointer`, `MatchIsKeyboard`, `MatchIsTouchpad`, `MatchDriver`, `MatchProduct`, `MatchDevicePath`. Con hotplug por `udev`, los dispositivos aparecen y desaparecen en tiempo de ejecución, así que una declaración estática no puede describir un mouse USB enchufado después de que arrancó el servidor.

**A5.4** — **Ambos.** Se fusionan, no son excluyentes: se leen los directorios de configuración y después se aplica `xorg.conf`, y según `xorg.conf(5)` las opciones de `xorg.conf` tienen precedencia sobre los archivos del directorio. Esta es la trampa detrás de "mi fragmento se ignora" — un `xorg.conf` monolítico remanente lo está sobrescribiendo silenciosamente.

**A5.5** — Esos archivos pertenecen a un paquete. La próxima actualización de `xorg-x11-drv-libinput` (o equivalente) sobrescribe tu edición o deja un `.rpmnew`/`.dpkg-dist` al lado, así que el cambio desaparece silenciosamente o silenciosamente deja de aplicarse. `/etc/X11/xorg.conf.d/` es el espacio de nombres del administrador, se lee después y sobrevive a las actualizaciones.

**A5.6** — En una prueba headless/de consola, `X :1` frecuentemente termina porque no puede tomar la VT, no tiene dispositivos de entrada para abrir, o termina cuando su (inexistente) cliente se desconecta — una falla de **runtime** después de un parseo exitoso. Un error de sintaxis real aparece *antes* de cualquier sondeo de dispositivos, como `(EE) Parse error on line N of section ... in file /etc/X11/xorg.conf.d/40-monitor.conf` seguido de `Fatal server error: no screens found`.

---

### Ejercicio 6

**A6.1** — `srv1.example.com` = **hostname**, la máquina que ejecuta el *servidor* X (la pantalla); `2` = **número de display**, qué instancia de servidor X en ese host (puerto TCP 6000+2, o socket `/tmp/.X11-unix/X2`); `1` = **número de screen**, qué pantalla dentro de ese display, significativo solo en configuraciones multi-screen (Zaphod). Omitir el screen usa `0` por defecto.

**A6.2** — `:0` (hostname vacío) usa el **socket de dominio Unix local** `/tmp/.X11-unix/X0`, que es más rápido y soporta verificación de credenciales del peer (`SI:localuser:`). `localhost:0` usa **TCP sobre la interfaz de loopback**, puerto 6000 — lo que requiere que el servidor se haya arrancado con `-listen tcp`, y por lo tanto normalmente falla en una instalación por defecto.

**A6.3** — `6000 + número_de_display` → **6004**. El display `:10` (el primer display reenviado por SSH) es el puerto 6010.

**A6.4** — La **laptop** ejecuta el servidor X, porque el servidor es dueño del hardware de pantalla, teclado y mouse. La máquina remota ejecuta el *cliente* (la aplicación). Esta inversión respecto de la intuición cliente/servidor habitual es un punto clásico de examen: el servidor está donde estás sentado.

**A6.5** — `Xvfb` implementa un servidor X completo en memoria sin salida de hardware, así que las aplicaciones gráficas, los toolkits y las herramientas de captura corren sin cambios en una máquina sin GPU ni monitor. `1280x1024x24` = ancho × alto × **profundidad de color en bits por píxel** (color verdadero de 24 bits) para el screen 0.

**A6.6** — `DISPLAY` **y** `XAUTHORITY`. `DISPLAY` le dice al cliente con qué servidor contactarse; sin `XAUTHORITY` (o un `~/.Xauthority` legible) el cliente no tiene credencial MIT-MAGIC-COOKIE-1 y es rechazado con `No protocol specified`. Cron arranca con un entorno mínimo y sin sesión, así que ambas deben definirse explícitamente.

---

### Ejercicio 7

**A7.1** — **Desactiva por completo el control de acceso basado en hosts**: cualquier cliente desde cualquier host que pueda alcanzar el servidor puede conectarse, sin cookie. X no tiene aislamiento por cliente, así que un cliente conectado puede (a) leer cada pulsación de tecla que va a cualquier ventana vía `XQueryKeymap`/las extensiones XTEST y RECORD — un keylogger completo, capturando contraseñas tipeadas en cualquier aplicación; (b) capturar el contenido de la pantalla (`xwd -root`) e inyectar eventos de entrada sintéticos en otras aplicaciones, por ejemplo tipear en una terminal de root. Equivale a entregar la sesión.

**A7.2** — **`MIT-MAGIC-COOKIE-1`**: un secreto compartido de 128 bits que el cliente envía al establecer la conexión. Se almacena en el archivo nombrado por `$XAUTHORITY`, con valor por defecto **`~/.Xauthority`**; los display managers frecuentemente lo sobrescriben con un archivo por sesión bajo `/run/user/<uid>/`.

**A7.3** — No se entera por el archivo. El servidor mantiene su lista de autorización en memoria, inicializada al arrancar a partir del argumento `-auth <file>` que le pasó el display manager. `xauth` edita el archivo del **lado cliente** para que los clientes presenten una cookie que el servidor ya acepta. Agregar una cookie nueva a tu archivo no otorga acceso; tenés que copiar una cookie *existente* y válida (que es exactamente lo que hace `xauth extract | xauth merge`).

**A7.4** — `No protocol specified` significa que el cliente **no tenía credencial que ofrecer** — `XAUTHORITY` sin definir/ilegible, o el archivo no tiene entrada para ese display. `Client is not authorized to connect to Server` significa que **se ofreció una credencial y fue rechazada** — una cookie obsoleta de una sesión anterior, o la entrada de display equivocada. El primero es un problema de búsqueda, el segundo un problema de coincidencia.

**A7.5** — La autorización de X es por cookie, no por UID; root no tiene ninguna posición especial en el protocolo X. El `~/.Xauthority` de root (`/root/.Xauthority`) no contiene ninguna cookie para el display del usuario. El arreglo correcto es `sudo XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:0 <command>`, o fusionar la cookie — no `xhost +`.

**A7.6** — Bajo GNOME/Wayland, mutter arranca Xwayland con `-auth` apuntando a un **archivo temporal por sesión** que creó en `$XDG_RUNTIME_DIR`, así que `~/.Xauthority` puede no existir o estar obsoleto. Un script que hardcodea `~/.Xauthority` (común en trabajos de cron, agentes de monitoreo y wrappers de `sudo`) va a fallar con `No protocol specified`. En su lugar, leé `$XAUTHORITY` del entorno de la sesión del usuario destino — por ejemplo desde `/proc/<pid>/environ` de un proceso de la sesión.

---

### Ejercicio 8

**A8.1** — SSH no reenvía hacia tu display real; crea un **endpoint de servidor X proxy en el host remoto** y tuneliza el protocolo de vuelta por el canal SSH cifrado. Ese endpoint vive en el loopback de la máquina remota, de ahí `localhost`. `X11DisplayOffset` (por defecto **10**) es el número de display más bajo que SSH puede asignar, manteniendo los displays reenviados lejos de los servidores locales reales en `:0`–`:9`.

**A8.2** — `-X` solicita reenvío **untrusted**: el cliente queda sujeto a la extensión **SECURITY** de X, que bloquea la captura de pantalla, la inyección de entrada hacia otros clientes y el acceso a recursos de otros clientes, y cuyo token expira después de `ForwardX11Timeout`. `-Y` solicita reenvío **trusted**: el cliente remoto tiene el mismo poder sobre tu display que uno local. Usá `-X` para hosts no confiables o compartidos; usá `-Y` solo para hosts que administrás vos, o cuando una aplicación genuinamente se rompe bajo las restricciones.

**A8.3** — (1) En el host **remoto**: `X11Forwarding yes` en `/etc/ssh/sshd_config` y `sshd` recargado. (2) En el host **remoto**: el binario `xauth` debe estar instalado — sin él sshd no puede crear la cookie del proxy y el reenvío falla incluso estando habilitado. (3) En el lado **local**: `ForwardX11 yes`/`-X`, más un `$DISPLAY` local funcional y una cookie local válida. Ejecutá `ssh -vv -X host` y leé el intercambio `debug1: Requesting X11 forwarding`.

**A8.4** — Enlazar a `127.0.0.1` significa que solo los procesos en el propio namespace de red del host remoto pueden alcanzar el puerto 6010; un contenedor con su propio namespace no puede. `X11UseLocalhost no` hace que sshd se enlace a la dirección comodín para que otros hosts/namespaces puedan conectarse — al costo de exponer el display reenviado a la red, que es por lo que `yes` es el valor por defecto. Preferí montar el socket por bind o usar `--network=host` antes que cambiar esto.

**A8.5** — **Confidencialidad**: X11 crudo sobre TCP va en texto plano — cada pulsación de tecla, título de ventana y píxel cruza la LAN sin cifrar y es trivialmente esnifable; SSH cifra todo el canal. **Autenticación**: `xhost +` autoriza por *nada en absoluto* (e incluso `xhost +host` autoriza a todo usuario de ese host, no a una persona), mientras que el reenvío por SSH emite una cookie por sesión atada a un login autenticado, y el modo untrusted además restringe lo que ese cliente puede hacer.

**A8.6** — `ssh -X` genera una cookie untrusted con una vida útil de `ForwardX11Timeout` (por defecto **20 minutos**); cuando expira, las conexiones nuevas al display son rechazadas. Arreglos: usar `-Y` (trusted, sin expiración) para un host en el que confiás, o elevar el límite con `-o ForwardX11Timeout=<seconds>` / una línea `ForwardX11Timeout` en `~/.ssh/config`. Notá que las ventanas ya abiertas normalmente sobreviven; son las conexiones *nuevas* las que fallan.

---

### Ejercicio 9

**A9.1** — Con **fuentes core de X**, el *servidor X* abre los archivos de fuente, rasteriza los glifos y se los envía al cliente; el cliente solo nombra una fuente con un XLFD y le pide al servidor que dibuje texto. Con **fontconfig/Xft**, el *cliente* abre el archivo de fuente, lo rasteriza localmente (FreeType), aplica antialiasing/hinting/renderizado subpíxel, y envía las imágenes de glifos resultantes al servidor a través de la extensión RENDER. Por eso las fuentes del lado cliente se ven idénticas local y remotamente, y por eso el font path del servidor es irrelevante para las aplicaciones modernas.

**A9.2** — `xfs` (X Font Server) centralizaba las fuentes core para que muchos servidores X — notablemente terminales X sin disco — pudieran compartir un único repositorio de fuentes por red en vez de instalar fuentes localmente cada uno. Escuchaba en el **puerto TCP 7100**. Quedó obsoleto porque el renderizado del lado cliente (Xft/fontconfig/RENDER) sacó el manejo de fuentes del servidor por completo, y porque el renderizado moderno escalado/antialiaseado/con hinting era imposible en el modelo de fuentes core. La mayoría de las distribuciones ya no lo incluyen.

**A9.3** — La sección **`Files`**. Ejemplo: `FontPath "tcp/fontsrv.example.com:7100"` (o `FontPath "unix/:7100"` para un `xfs` local, y `FontPath "/usr/share/fonts/X11/misc/"` para un directorio simple).

**A9.4** — Cuentan cosas distintas. `xlsfonts` lista las **fuentes core conocidas por el servidor X** a través de su font path — una instalación moderna trae solo un puñado de built-ins más `fixed`/`cursor`. `fc-list` lista las **fuentes de fontconfig disponibles para los clientes** desde `/usr/share/fonts`, `~/.local/share/fonts`, etc. Las aplicaciones usan casi exclusivamente el segundo conjunto, así que 17 fuentes core es normal y saludable.

**A9.5** — `mkfontscale` genera **`fonts.scale`** (un índice de fuentes escalables — TTF/OTF/Type1 — con sus nombres XLFD) y `mkfontdir` genera **`fonts.dir`** (el índice combinado que el servidor realmente lee). `xset fp rehash` le dice a un servidor *en ejecución* que vuelva a leer los directorios de su font path, así las fuentes core recién agregadas se toman sin reiniciar X.

**A9.6** — `fc-cache -f` (opcionalmente `-v`, opcionalmente con el directorio). Fontconfig cachea los escaneos de directorios; hasta que se refresque la caché, `fc-list`/`fc-match` no ven el archivo nuevo. Cerrar sesión es innecesario porque cada cliente consulta a fontconfig al momento de buscar la fuente — aunque las aplicaciones ya en ejecución típicamente necesitan reiniciarse para volver a consultar la lista de fuentes.

---

### Ejercicio 10

**A10.1** — El **log de Xorg** lo escribe el *servidor* X: sondeo de hardware, carga de drivers y módulos, fuentes de configuración, EDID y modos, inicialización de extensiones, errores fatales del servidor. **`~/.xsession-errors`** recolecta stdout/stderr de los *clientes de la sesión* — los scripts `Xsession`, el window manager, el panel, las aplicaciones de autostart. El servidor no arranca → log de Xorg. El servidor arranca pero el escritorio está roto/vacío → `.xsession-errors`.

**A10.2** — (1) Ningún driver utilizable: el `Driver` configurado no existe, o ningún DDX coincidió con el hardware (`No drivers available`). (2) Ningún dispositivo KMS: driver del kernel no cargado, `nomodeset` en la línea de comandos del kernel, GPU en passthrough/reclamada por otro driver, o permisos de `/dev/dri/card0`. (3) Desajuste de configuración: una sección `Device` fijada al `BusID` equivocado, o rangos de sincronismo de `Monitor` que excluyen todos los modos sondeados, con lo que no queda ningún modo válido.

**A10.3** — `sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.disabled` (quitar la configuración ofensiva para que X autodetecte) y `sudo systemctl set-default multi-user.target` (arrancar a un login de texto sin importar qué). El segundo comando por sí solo garantiza un prompt de login; el primero elimina la causa probable. Restauralo con `systemctl set-default graphical.target` una vez arreglado.

**A10.4** — No toca nada de lo que depende el sistema en ejecución: usa un número de display libre, escribe su log en una ruta que elegís vos, no detiene el display manager, no cierra la sesión del usuario, y muere inofensivamente si la configuración está mal. Reiniciar el display manager termina todos los procesos gráficos — trabajo sin guardar incluido — y si la nueva configuración está rota, perdés el entorno desde el que estabas depurando.

**A10.5** — `~/.xsession-errors` lo producen los tradicionales scripts de shell `Xsession`, que las sesiones basadas en systemd ya no usan. La salida de los clientes va al **journal de systemd**: `journalctl --user -b` para toda la sesión de usuario, `journalctl --user -b -u <unit>` para un servicio, o `journalctl -b _COMM=gnome-shell` / `_COMM=gdm-x-session` para un binario específico.

**A10.6** — Un cliente atascado en un bucle de errores está escribiendo a stderr miles de veces por segundo — un applet de panel que crashea, un método de entrada mal configurado, o una tormenta de warnings de GTK/Qt. El archivo no rota y vive en el home del usuario, así que puede agotar el sistema de archivos `/home` o la cuota del usuario, lo que a su vez rompe *el login mismo* (la sesión no puede escribir sus dotfiles). Diagnosticalo con `sort ~/.xsession-errors | uniq -c | sort -rn | head` para encontrar el mensaje repetido.

---

### Ejercicio 11

**A11.1** — **X11**: un único servidor gráfico (Xorg) es dueño del hardware; el window manager es un cliente X separado y común que posiciona las ventanas; un compositor es otro cliente opcional más. **Wayland**: el compositor *es* el servidor gráfico *y* el window manager — un solo proceso es dueño de la salida KMS/DRM, la entrada vía libinput, y la composición. Consecuencia: los clientes no pueden inspeccionarse ni manipularse entre sí, porque no hay un servidor compartido al que preguntarle.

**A11.2** — Xwayland es una implementación de servidor X que renderiza clientes X dentro de superficies Wayland, permitiendo que aplicaciones X11 no portadas corran en una sesión Wayland. Reclama un número de display X (normalmente `:0`) y el compositor exporta `DISPLAY` para que esos clientes lo encuentren. Por eso que `DISPLAY` esté definida no prueba nada sobre el tipo de sesión.

**A11.3** — El mode setting le corresponde al **compositor**, que es el DRM master; Xwayland es rootless y no tiene CRTCs propios, así que las solicitudes de mode setting de RandR fallan. La configuración se hace a través de la interfaz propia del compositor — GNOME Settings/`gnome-monitor-config`, `kscreen-doctor` de KDE, `sway output ...`, o `wlr-randr` en compositores wlroots.

**A11.4** — Los clientes Wayland nativos nunca se conectan a Xwayland, y el protocolo Wayland no le da a ningún cliente la capacidad de enumerar, leer o inyectar en las ventanas de otro cliente. `xdotool` habla X11 y por lo tanto solo puede ver clientes de Xwayland. Esto es deliberado: elimina exactamente las capacidades de keylogging e inyección de entrada descritas en A7.1, que eran irreparables en el diseño de X11.

**A11.5** — La interfaz de screen-cast de **`xdg-desktop-portal`** (`org.freedesktop.portal.ScreenCast`), respaldada por **PipeWire**, con el compositor pidiéndole al usuario su consentimiento y que elija qué compartir. Las capturas directas del framebuffer (`xwd -root`, APIs de captura de pantalla de X11) ven solo la capa de Xwayland, y por eso la grabación sale negra.

**A11.6** — Sí, pero con un alcance **acotado**: desactiva el control de acceso únicamente en el servidor **Xwayland**. Cualquier proceso local podría entonces conectarse a Xwayland y espiar o inyectar en los clientes X11 que corren ahí — lo que, en un escritorio típico, todavía incluye navegadores o aplicaciones Electron en modo X11, emuladores de terminal y herramientas legacy. Los clientes Wayland nativos no se ven afectados. Sigue estando mal hacerlo, solo que ya no es un compromiso de toda la sesión.

</details>

---

## Fuentes

* LPI — Exam 101 Objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
* X.Org — manual del archivo de configuración `xorg.conf(5)`: <https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml>
* X.Org — manual del servidor `Xorg(1)`: <https://www.x.org/releases/current/doc/man/man1/Xorg.1.xhtml>
* X.Org — `X(7)`, nombres de display y control de acceso: <https://www.x.org/releases/current/doc/man/man7/X.7.xhtml>
* X.Org — `xauth(1)`: <https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml>
* X.Org — `xhost(1)`: <https://www.x.org/releases/current/doc/man/man1/xhost.1.xhtml>
* X.Org — `Xephyr(1)` y `Xvfb(1)`: <https://www.x.org/releases/current/doc/man/man1/Xephyr.1.xhtml>, <https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml>
* Wiki de X.Org — fuentes y la deprecación del sistema de fuentes core: <https://www.x.org/wiki/Development/Documentation/Fonts/>
* freedesktop.org — documentación de usuario de fontconfig: <https://www.freedesktop.org/software/fontconfig/fontconfig-user.html>
* freedesktop.org — arquitectura de Wayland: <https://wayland.freedesktop.org/architecture.html>
* freedesktop.org — Xwayland: <https://wayland.freedesktop.org/xserver.html>
* freedesktop.org — xdg-desktop-portal (ScreenCast): <https://flatpak.github.io/xdg-desktop-portal/docs/>
* OpenSSH — `ssh(1)` y `sshd_config(5)` (opciones de reenvío X11): <https://man.openbsd.org/ssh>, <https://man.openbsd.org/sshd_config>
* Kernel de Linux — documentación de Direct Rendering Manager (DRM/KMS): <https://docs.kernel.org/gpu/drm-uapi.html>
* systemd — `loginctl(1)` y tipos de sesión: <https://www.freedesktop.org/software/systemd/man/latest/loginctl.html>