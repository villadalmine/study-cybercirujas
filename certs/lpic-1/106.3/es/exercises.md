# LPIC-1 — Tema 106.3: Accesibilidad
## Ejercicios guiados (Examen 102-500, versión 5.0)

> **Alcance del objetivo.** *Accesibilidad* cubre las tecnologías asistivas que exponen un escritorio Linux y una consola de texto Linux: ajustes visuales y temas, magnificador de pantalla, lector de pantalla, línea braille, accesibilidad de teclado en el escritorio (AccessX: Sticky/Slow/Bounce/Toggle/Repeat/Mouse Keys), gestos, teclado en pantalla y síntesis de voz.
> Lista oficial de objetivos: <https://www.lpi.org/our-certifications/exam-102-objectives/> (la lista de objetivos 101 referenciada en el encabezado del temario cubre los temas 101–104; 106.x vive en la lista 102-500).

### Antes de empezar

Estos ejercicios **modifican el estado de una sesión de escritorio en marcha**. Ejecutalos en una VM descartable o en una imagen live, o prepará la vuelta atrás — cada bloque termina con un paso explícito de rollback.

Paquetes usados a lo largo de los ejercicios (nombres para Debian/Ubuntu, y luego Fedora/RHEL):

```bash
# Debian / Ubuntu
sudo apt install x11-xserver-utils xkbset xinput xdotool xvkbd onboard \
     at-spi2-core python3-pyatspi accerciser espeak-ng festival \
     speech-dispatcher speech-dispatcher-espeak-ng orca brltty brltty-x11 \
     kbd console-setup xzoom

# Fedora / RHEL
sudo dnf install xorg-x11-server-utils xkbset xinput xdotool xvkbd onboard \
     at-spi2-core accerciser espeak-ng festival \
     speech-dispatcher speech-dispatcher-espeak orca brltty brltty-at-spi2 \
     kbd
```

Todo lo que empieza con `x` (`xset`, `xkbset`, `xvkbd`, `xdotool`, `xprop`, `xev`) habla el protocolo X11. Bajo una sesión Wayland esas herramientas fallan o sólo afectan a clientes XWayland — el Bloque 1 te hace determinar en qué mundo estás **antes** de sacar conclusiones a partir de ellas.

---

## Bloque 1 — Reconocimiento: ¿qué stack de accesibilidad estoy ejecutando realmente?

**Objetivo:** establecer el servidor gráfico, el puente del toolkit y el inventario de tecnologías asistivas instaladas, para que los fallos posteriores se atribuyan a la capa correcta.

1. Identificá el tipo de sesión y el seat:

   ```bash
   echo "$XDG_SESSION_TYPE"
   loginctl show-session "$(loginctl show-user "$USER" -p Display --value)" \
       -p Id -p Type -p Class -p Remote -p Active
   ```

   ```
   x11
   Id=2
   Type=x11
   Class=user
   Remote=no
   Active=yes
   ```

2. Identificá el entorno de escritorio, porque las claves GSettings usadas en los Bloques 4 y 5 son esquemas de GNOME:

   ```bash
   echo "$XDG_CURRENT_DESKTOP" "$DESKTOP_SESSION"
   ```

3. Listá los procesos relacionados con accesibilidad que ya están corriendo:

   ```bash
   ps -ef | grep -E 'at-spi|orca|brltty|onboard|speech-dispatcher' | grep -v grep
   ```

   ```
   user  1531  1  0 09:12 ?  00:00:00 /usr/libexec/at-spi-bus-launcher
   user  1540  1  0 09:12 ?  00:00:00 /usr/libexec/at-spi2-registryd --use-gnome-session
   ```

4. Inventariá lo que está instalado pero no corriendo:

   ```bash
   for b in orca brltty xbrlapi onboard xvkbd espeak-ng espeak festival \
            spd-say accerciser xzoom kmag setfont setterm kbdrate xkbset; do
       printf '%-12s %s\n' "$b" "$(command -v "$b" || echo '-- not installed --')"
   done
   ```

5. Comprobá si los esquemas de accesibilidad de GNOME existen en esta máquina (vienen con `gsettings-desktop-schemas`, con independencia de que GNOME Shell esté corriendo o no):

   ```bash
   gsettings list-schemas | grep -i a11y | sort
   ```

   ```
   org.gnome.desktop.a11y
   org.gnome.desktop.a11y.applications
   org.gnome.desktop.a11y.interface
   org.gnome.desktop.a11y.keyboard
   org.gnome.desktop.a11y.magnifier
   org.gnome.desktop.a11y.mouse
   ```

6. Registrá una línea base de todo lo que estás por modificar, para poder comparar después:

   ```bash
   mkdir -p ~/a11y-lab
   gsettings list-recursively org.gnome.desktop.a11y            > ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.a11y.keyboard  >> ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.a11y.magnifier >> ~/a11y-lab/base-a11y.txt
   gsettings list-recursively org.gnome.desktop.interface      >> ~/a11y-lab/base-a11y.txt
   dconf dump /org/gnome/desktop/a11y/ > ~/a11y-lab/base-a11y.dconf
   [ "$XDG_SESSION_TYPE" = x11 ] && xkbset q > ~/a11y-lab/base-xkb.txt
   wc -l ~/a11y-lab/*
   ```

**Comprobá lo aprendido**

- **Q1.1** Ejecutás `xkbset q` y obtenés `Can't open display`. Dá dos causas raíz distintas y el comando que las distingue.
- **Q1.2** `at-spi2-registryd` está corriendo pero `at-spi-bus-launcher` no. ¿Qué está roto, y qué hace cada uno de esos dos procesos?
- **Q1.3** ¿Por qué `gsettings list-schemas | grep a11y` devuelve resultados en una máquina que corre KDE Plasma sin ninguna sesión GNOME instalada?
- **Q1.4** ¿Cuáles de las herramientas del paso 4 son inútiles en una sesión Wayland pura, y cuál de ellas sigue funcionando porque no toca el servidor gráfico en absoluto?

---

## Bloque 2 — El bus de accesibilidad AT-SPI2

**Objetivo:** entender el transporte del que dependen todo lector de pantalla gráfico, todo seguimiento de magnificador y todo teclado en pantalla. AT-SPI2 (Assistive Technology Service Provider Interface, v2) es un protocolo **D-Bus**: las aplicaciones exportan su árbol de widgets como objetos accesibles, y las herramientas asistivas lo consumen. Referencia: <https://www.freedesktop.org/wiki/Accessibility/AT-SPI2/>

1. Preguntale al bus de sesión dónde vive el bus de accesibilidad:

   ```bash
   gdbus call --session --dest org.a11y.Bus \
              --object-path /org/a11y/bus \
              --method org.a11y.Bus.GetAddress
   ```

   ```
   ('unix:path=/run/user/1000/at-spi/bus_0,guid=1f3c...',)
   ```

2. Bajo X11, la misma dirección se publica como una propiedad en la ventana raíz — éste es el camino de respaldo que usan los toolkits que no pueden alcanzar el bus de sesión:

   ```bash
   xprop -root AT_SPI_BUS
   ```

   ```
   AT_SPI_BUS(STRING) = "unix:path=/run/user/1000/at-spi/bus_0,guid=1f3c..."
   ```

3. Leé el interruptor maestro del toolkit. Esta clave es lo que realmente hace que las aplicaciones GTK y Qt carguen sus puentes de accesibilidad:

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   gsettings set org.gnome.desktop.interface toolkit-accessibility true
   ```

4. Arrancá una aplicación GTK **con** y **sin** el puente y compará. `NO_AT_BRIDGE=1` es la vía de escape de GTK; `QT_ACCESSIBILITY=1` es el equivalente de Qt:

   ```bash
   gedit &                       # or gnome-text-editor / any GTK app
   NO_AT_BRIDGE=1 gedit &
   ```

5. Enumerá las aplicaciones actualmente visibles en el bus de accesibilidad:

   ```bash
   python3 - <<'PY'
   import pyatspi
   for app in pyatspi.Registry.getDesktop(0):
       print(f"{app.name:<28} role={app.getRoleName():<20} children={app.childCount}")
   PY
   ```

   ```
   gedit                        role=application         children=1
   gnome-shell                  role=application         children=3
   ```

   La aplicación lanzada con `NO_AT_BRIDGE=1` está ausente de esa lista.

6. Observá el tráfico del bus mientras movés el foco entre widgets — esto es exactamente a lo que Orca se suscribe:

   ```bash
   dbus-monitor --address "$(busctl --user call org.a11y.Bus /org/a11y/bus \
        org.a11y.Bus GetAddress | cut -d'"' -f2)" \
        "type='signal',interface='org.a11y.atspi.Event.Object'" | head -40
   ```

7. Inspeccioná el mismo árbol de forma interactiva:

   ```bash
   accerciser &
   ```

8. Restaurá el valor original de `toolkit-accessibility` desde tu archivo de línea base si lo cambiaste.

**Comprobá lo aprendido**

- **Q2.1** ¿Por qué AT-SPI2 usa un daemon D-Bus *separado* en lugar del bus de sesión ordinario?
- **Q2.2** Una aplicación aparece en pantalla pero Orca no anuncia nada y falta en el listado de `pyatspi`. Enumerá tres causas independientes, ordenadas de más a menos probable.
- **Q2.3** ¿Cuál es la diferencia práctica entre `toolkit-accessibility=false` y `NO_AT_BRIDGE=1`?
- **Q2.4** Un usuario reporta que la accesibilidad funciona en aplicaciones GTK pero no en una Qt. ¿Qué variable de entorno revisás primero, y por qué el lado GTK no se ve afectado por ella?

---

## Bloque 3 — AccessX: accesibilidad de teclado en X11

**Objetivo:** manejar Sticky Keys, Slow Keys, Bounce Keys, Toggle Keys, Repeat Keys y Mouse Keys directamente a través de la extensión XKB, por debajo de la GUI de configuración del escritorio. `xkbset` manipula `XkbSetControls`; `xset` manipula los controles de teclado del núcleo (core).

1. Volcá el estado AccessX actual y dejalo a la vista en una segunda terminal:

   ```bash
   xkbset q
   ```

   ```
   Bell Settings:
       On - AudibleBell      On - Bell (Global)
   Sticky Keys:
       Off - StickyKeys
       Off - TwoKeys         Off - LatchLock
   Mouse Keys:
       Off - MouseKeys       Off - MouseKeysAccel
        Delay: 160    Interval: 40    Time to Max: 30
        Max Speed: 10   Curve: 0
   Access X Keys:
       Off - AccessXKeys
   Access X Timeout:
        Timeout: 0    ...
   Slow Keys:
       Off - SlowKeys
        Delay: 300
   Bounce Keys:
       Off - BounceKeys
        Delay: 300
   ```

   *(Salida abreviada; el orden de los campos varía levemente entre versiones.)*

2. Activá **Sticky Keys** y probalo. Sticky Keys retiene un modificador para que `Ctrl`+`Alt`+`Del` pueda tipearse una tecla por vez:

   ```bash
   xkbset sticky -twokey -latchlock
   xkbset q | grep -A2 'Sticky'
   ```

   Ahora presioná `Ctrl`, soltalo, y después presioná `T` en una aplicación capaz de recibir texto de terminal. El modificador se aplicó aunque no se lo mantuvo presionado.

   * `-twokey` desactiva "presionar dos teclas a la vez apaga Sticky Keys".
   * `-latchlock` desactiva "presionar un modificador dos veces lo bloquea".

3. Activá las **secuencias de teclas AccessX**, que permiten a un usuario encender funciones sin ratón:

   ```bash
   xkbset a
   ```

   Ahora: presioná `Shift` cinco veces seguidas → Sticky Keys conmuta. Mantené `Shift` durante ocho segundos → Slow Keys conmuta.

4. Lidiá con el **timeout de AccessX**, la trampa clásica: las funciones AccessX se apagan automáticamente tras un período de inactividad. Declará qué funciones deben sobrevivir al timeout:

   ```bash
   xkbset exp '=sticky' '=twokey' '=latchlock' '=mousekeys' '=accessx'
   xkbset q | grep -A6 'Timeout'
   man 1 xkbset      # confirm the exact expiry syntax of your version
   ```

5. **Slow Keys** — una tecla debe mantenerse presionada durante *N* milisegundos antes de registrarse, lo que filtra roces involuntarios contra el teclado. Poné unos 800 ms deliberadamente evidentes y tipeá:

   ```bash
   xkbset sl 800
   xkbset q | grep -A2 'Slow'
   # ...type something, notice the lag...
   xkbset -sl
   ```

6. **Bounce Keys** (o debounce) — una pulsación repetida de la *misma* tecla se ignora durante *N* ms, lo que filtra el temblor:

   ```bash
   xkbset bo 700
   # hammer the "a" key: only the first press per 700 ms registers
   xkbset -bo
   ```

7. **Mouse Keys** — manejar el puntero desde el teclado numérico:

   ```bash
   xkbset m
   xkbset ma 60 10 10 20 5     # delay interval time_to_max max_speed curve
   xkbset exp '=mousekeys' '=mousekeysaccel'
   ```

   Con NumLock en el estado apropiado: `8/2/4/6` mueven el puntero, `5` hace clic, `+` hace doble clic, `/ * -` seleccionan el botón izquierdo/medio/derecho.

8. **Repeat Keys** — la autorrepetición es un control X del núcleo, no uno de AccessX. Ralentizá la repetición para un usuario que no puede soltar las teclas rápido:

   ```bash
   xset q | sed -n '/Keyboard Control/,/^$/p'
   xset r rate 1000 8          # 1000 ms delay, 8 repeats/second
   xset -r 36                  # disable auto-repeat for keycode 36 (Return) only
   xset r 36                   # re-enable it
   ```

   Encontrá un keycode con `xev -event keyboard | grep keycode`.

9. **Toggle Keys** — un pitido audible cuando un modificador de bloqueo cambia de estado. En X éste es el grupo de retroalimentación de AccessX; el interruptor a nivel de escritorio se cubre en el Bloque 4:

   ```bash
   xkbset bell               # ensure the bell is on
   xset b 100 1000 100       # volume% pitch(Hz) duration(ms)
   xkbset q | grep -A4 'Feedback'
   ```

10. Revertí todo:

    ```bash
    xkbset -sticky -twokey -latchlock -m -ma -sl -bo -a
    xset r rate 660 25
    xkbset q | diff -u ~/a11y-lab/base-xkb.txt - || echo "state differs — inspect above"
    ```

**Comprobá lo aprendido**

- **Q3.1** Distinguí Slow Keys de Bounce Keys en una oración cada una, y dá la discapacidad que atiende cada una.
- **Q3.2** Un usuario activa Mouse Keys con `xkbset m`, funciona, y ~2 minutos después deja de funcionar. ¿Qué pasó y cuál es la solución?
- **Q3.3** ¿Por qué Repeat Keys se configura con `xset` mientras que Sticky Keys se configura con `xkbset`?
- **Q3.4** Sticky Keys está activo, y el usuario se queja de que "se apaga solo al azar". ¿Qué dos subopciones de `xkbset` son responsables, y cómo las neutralizás?
- **Q3.5** Con Sticky Keys activado pero `latchlock` encendido, ¿qué pasa si el usuario presiona `Shift` dos veces?
- **Q3.6** Necesitás suprimir la autorrepetición por keycode para una única tecla trabada. ¿Qué comando, y cómo obtenés el keycode?

---

## Bloque 4 — GSettings/dconf: el árbol de accesibilidad a nivel de escritorio

**Objetivo:** configurar las mismas funciones a través de la capa que usa el panel gráfico de Configuración, y observar la relación entre ambas capas. `gsettings` es el front end CLI de dconf; `org.gnome.desktop.a11y.*` es donde el escritorio guarda el estado de accesibilidad.

1. Abrí un observador en una segunda terminal y dejalo corriendo durante todo el bloque:

   ```bash
   dconf watch /org/gnome/desktop/a11y/
   ```

2. Enumerá las claves de accesibilidad de teclado y sus valores actuales:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.keyboard | sort
   ```

   ```
   org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject false
   org.gnome.desktop.a11y.keyboard bouncekeys-delay 300
   org.gnome.desktop.a11y.keyboard bouncekeys-enable false
   org.gnome.desktop.a11y.keyboard enable false
   org.gnome.desktop.a11y.keyboard mousekeys-accel-time 1200
   org.gnome.desktop.a11y.keyboard mousekeys-enable false
   org.gnome.desktop.a11y.keyboard mousekeys-init-delay 160
   org.gnome.desktop.a11y.keyboard mousekeys-max-speed 750
   org.gnome.desktop.a11y.keyboard slowkeys-beep-accept false
   org.gnome.desktop.a11y.keyboard slowkeys-delay 300
   org.gnome.desktop.a11y.keyboard slowkeys-enable false
   org.gnome.desktop.a11y.keyboard stickykeys-enable false
   org.gnome.desktop.a11y.keyboard stickykeys-modifier-beep true
   org.gnome.desktop.a11y.keyboard stickykeys-two-key-off true
   org.gnome.desktop.a11y.keyboard togglekeys-enable false
   ```

3. Encendé el interruptor maestro de AccessX y Sticky Keys a través de la capa de escritorio, y luego verificá que la capa X cambió por debajo:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard enable true
   gsettings set org.gnome.desktop.a11y.keyboard stickykeys-enable true
   xkbset q | grep -A2 'Sticky'
   ```

4. Configurá Slow Keys y Bounce Keys con retroalimentación audible:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-delay 500
   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-beep-accept true
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-delay 500
   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-beep-reject true
   ```

5. Activá **Toggle Keys** — el pitido en Caps/Num/Scroll Lock — que no tiene un subcomando `xkbset` directo:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard togglekeys-enable true
   ```

6. Encendé las tres aplicaciones asistivas desde la CLI. Éstas son exactamente las claves que escribe el panel Configuración → Accesibilidad:

   ```bash
   gsettings list-keys org.gnome.desktop.a11y.applications
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
   ```

7. Mostrá el menú de accesibilidad en la barra superior para que el estado sea visible sin la CLI:

   ```bash
   gsettings set org.gnome.desktop.a11y always-show-universal-access-status true
   ```

8. Explorá el esquema de puntero/asistencia al clic (clic por permanencia y retardo de clic secundario), que es el lado de los "gestos" del objetivo en un escritorio:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.mouse
   gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
   gsettings set org.gnome.desktop.a11y.mouse dwell-time 1.2
   gsettings set org.gnome.desktop.a11y.mouse secondary-click-enabled true
   gsettings set org.gnome.desktop.a11y.mouse secondary-click-time 1.5
   ```

9. Reseteá una sola clave, y después un esquema entero:

   ```bash
   gsettings reset org.gnome.desktop.a11y.keyboard slowkeys-delay
   gsettings reset-recursively org.gnome.desktop.a11y.keyboard
   ```

10. Restaurá la línea base completa capturada en el Bloque 1:

    ```bash
    dconf load /org/gnome/desktop/a11y/ < ~/a11y-lab/base-a11y.dconf
    dconf dump  /org/gnome/desktop/a11y/ | diff -u ~/a11y-lab/base-a11y.dconf - \
        && echo "a11y tree restored"
    ```

**Comprobá lo aprendido**

- **Q4.1** Ponés `stickykeys-enable true` pero `xkbset q` sigue mostrando `Off - StickyKeys`. Nombrá la causa más probable y la clave que lo arregla.
- **Q4.2** ¿Cuál es la relación entre `gsettings` y `dconf`, y dónde vive físicamente el valor?
- **Q4.3** `dconf watch /org/gnome/desktop/a11y/` no imprime nada mientras hacés clic en los interruptores del panel de Accesibilidad. ¿Qué te dice eso sobre la sesión en ejecución?
- **Q4.4** ¿Cuál es autoritativo en tiempo de ejecución — la clave GSettings o el control XKB — y qué le pasa a tu cambio de `xkbset` cuando el daemon de configuración se reinicia?
- **Q4.5** ¿Cómo aplicarías `stickykeys-enable=true` a *todos* los usuarios de una máquina, no sólo a vos?

---

## Bloque 5 — Accesibilidad visual: contraste, letra grande, cursor, magnificador

**Objetivo:** configurar temas de alto contraste y letra grande, el tamaño del cursor y el magnificador de pantalla, y entender la diferencia entre escalar el texto y escalar toda la salida.

1. Inspeccioná el esquema de interfaz, que contiene los ajustes de tema y fuente:

   ```bash
   gsettings list-recursively org.gnome.desktop.interface | \
       grep -E 'theme|font|cursor|scaling'
   ```

   ```
   org.gnome.desktop.interface cursor-size 24
   org.gnome.desktop.interface cursor-theme 'Adwaita'
   org.gnome.desktop.interface font-name 'Cantarell 11'
   org.gnome.desktop.interface gtk-theme 'Adwaita'
   org.gnome.desktop.interface icon-theme 'Adwaita'
   org.gnome.desktop.interface text-scaling-factor 1.0
   ```

2. Activá **Alto contraste**. GNOME moderno tiene una clave dedicada; las versiones más viejas cambian el nombre del tema. Comprobá cuál ofrece tu sistema y usá ésa:

   ```bash
   gsettings list-keys org.gnome.desktop.a11y.interface
   # if 'high-contrast' is listed:
   gsettings set org.gnome.desktop.a11y.interface high-contrast true
   # legacy / non-GNOME-Shell path:
   gsettings set org.gnome.desktop.interface gtk-theme  'HighContrast'
   gsettings set org.gnome.desktop.interface icon-theme 'HighContrast'
   ```

   Confirmá que el tema esté realmente instalado antes de culpar a la clave:

   ```bash
   ls -d /usr/share/themes/HighContrast* /usr/share/icons/HighContrast* 2>/dev/null
   ```

3. Activá **Letra grande**. `text-scaling-factor` es el control de accesibilidad; escala todo el texto sin cambiar las métricas de disposición:

   ```bash
   gsettings set org.gnome.desktop.interface text-scaling-factor 1.5
   # compare against changing the font itself:
   gsettings set org.gnome.desktop.interface font-name 'Cantarell 16'
   ```

4. Agrandá el puntero, que es un eje separado del tamaño del texto:

   ```bash
   gsettings set org.gnome.desktop.interface cursor-size 48
   gsettings set org.gnome.desktop.a11y.interface show-status-shapes true 2>/dev/null
   ```

5. Configurá el **magnificador de pantalla** antes de encenderlo:

   ```bash
   gsettings list-recursively org.gnome.desktop.a11y.magnifier | sort | head -20
   gsettings set org.gnome.desktop.a11y.magnifier mag-factor 3.0
   gsettings set org.gnome.desktop.a11y.magnifier screen-position 'full-screen'
   gsettings set org.gnome.desktop.a11y.magnifier mouse-tracking 'proportional'
   gsettings set org.gnome.desktop.a11y.magnifier cross-hairs-length 4096
   gsettings set org.gnome.desktop.a11y.magnifier show-cross-hairs true
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
   ```

6. Probá el modo lente, que magnifica sólo alrededor del puntero:

   ```bash
   gsettings set org.gnome.desktop.a11y.magnifier lens-mode true
   gsettings set org.gnome.desktop.a11y.magnifier screen-position 'centered'
   ```

7. Aplicá un efecto de inversión de color para usuarios con sensibilidad a la luz:

   ```bash
   gsettings set org.gnome.desktop.a11y.magnifier invert-lightness true
   gsettings set org.gnome.desktop.a11y.magnifier contrast-red   0.5
   gsettings set org.gnome.desktop.a11y.magnifier brightness-red 0.2
   ```

8. Compará con los magnificadores X independientes, que no dependen del escritorio:

   ```bash
   xzoom -mag 4 &        # continuously magnified follow-the-pointer window
   xmag &                # one-shot snapshot magnifier
   kmag &                # KDE magnifier
   ```

9. Revertí:

   ```bash
   gsettings reset-recursively org.gnome.desktop.a11y.magnifier
   gsettings reset org.gnome.desktop.interface text-scaling-factor
   gsettings reset org.gnome.desktop.interface cursor-size
   gsettings reset org.gnome.desktop.interface gtk-theme
   gsettings reset org.gnome.desktop.interface icon-theme
   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled false
   ```

**Comprobá lo aprendido**

- **Q5.1** `text-scaling-factor 1.5` frente a `font-name 'Cantarell 16'` frente al `scaling-factor` de pantalla — ¿qué escala realmente cada uno, y cuál es el control de accesibilidad?
- **Q5.2** Ponés `gtk-theme 'HighContrast'` y no cambia nada. Dá las dos primeras cosas que revisás.
- **Q5.3** ¿Por qué un magnificador de pantalla necesita saber algo del bus AT-SPI, si sólo agranda píxeles?
- **Q5.4** ¿Cuál es la diferencia funcional entre `screen-position 'full-screen'` y `lens-mode true`?
- **Q5.5** Un usuario necesita magnificación pero el magnificador del escritorio no está disponible (WM mínimo, sin GNOME Shell). Nombrá dos alternativas y su limitación.

---

## Bloque 6 — Síntesis de voz: espeak-ng, Festival y Speech Dispatcher

**Objetivo:** construir el stack de voz de abajo hacia arriba — el sintetizador, y después la capa de abstracción Speech Dispatcher con la que realmente hablan Orca y otros clientes.

1. Verificá primero la salida de audio; un stack de voz mudo suele ser un stack de *audio* mudo:

   ```bash
   speaker-test -t sine -f 440 -l 1 -c 2
   aplay -l
   ```

2. Hablá directamente con **espeak-ng**, un sintetizador de formantes: chico, rápido, ~100 idiomas, robótico:

   ```bash
   espeak-ng "The quick brown fox jumps over the lazy dog"
   espeak-ng -v en-gb -s 130 -p 40 -a 200 "Rate one thirty, pitch forty, amplitude two hundred"
   espeak-ng -v es -s 160 "Prueba de síntesis de voz en español"
   ```

   * `-v` voz/idioma, `-s` palabras por minuto, `-p` tono 0–99, `-a` amplitud 0–200.

3. Enumerá las voces y renderizá a un archivo en lugar de a la placa de sonido:

   ```bash
   espeak-ng --voices | head -12
   ```

   ```
   Pty Language Age/Gender VoiceName          File                 Other Languages
    5  af       --/M      Afrikaans          gmw/af
    5  en-gb    --/M      english            gmw/en
    5  en-us    --/M      english-us         gmw/en-US
   ```

   ```bash
   espeak-ng -v en-us -w /tmp/sample.wav "Written to a wave file"
   aplay /tmp/sample.wav
   espeak-ng --stdout "Piped through standard output" | aplay -q
   ```

4. Inspeccioná la capa de fonemas — útil al diagnosticar reportes de mala pronunciación:

   ```bash
   espeak-ng -x -q "Linux accessibility"
   espeak-ng --ipa -q "Linux accessibility"
   ```

5. Hablá con **Festival**, un motor concatenativo / de selección de unidades: más grande, más lento, más natural:

   ```bash
   echo "Festival speech synthesis system" | festival --tts
   festival -b '(SayText "Batch mode invocation")'
   echo "Rendered offline" | text2wave -o /tmp/festival.wav && aplay /tmp/festival.wav
   ```

6. Ahora la capa de abstracción. **Speech Dispatcher** (`speechd`) multiplexa varios clientes sobre un único sintetizador y arbitra prioridades. Listá sus módulos de salida:

   ```bash
   spd-say -O
   ```

   ```
   Output modules:
   espeak-ng
   espeak-ng-mbrola-generic
   festival
   ```

7. Hablá a través de él, y observá que el cliente nunca nombra un sintetizador:

   ```bash
   spd-say "Hello from speech dispatcher"
   spd-say -o festival -r -30 -p 20 "Festival module, slower and lower"
   spd-say -l es "Mensaje en español"
   spd-say -L | head
   spd-say -C                      # cancel everything currently speaking
   ```

8. Definí el módulo y la voz por defecto a nivel de sistema, y después por usuario:

   ```bash
   grep -nE '^\s*(DefaultModule|DefaultLanguage|DefaultVoiceType|AudioOutputMethod)' \
        /etc/speech-dispatcher/speechd.conf
   ```

   ```
   77:DefaultModule espeak-ng
   84:DefaultLanguage "en"
   112:DefaultVoiceType  "MALE1"
   198:AudioOutputMethod "pulse"
   ```

   ```bash
   spd-conf                        # creates ~/.config/speech-dispatcher/ and self-tests
   ls ~/.config/speech-dispatcher/
   ```

9. Diagnosticá un stack mudo de forma metódica:

   ```bash
   systemctl --user status speech-dispatcher.service
   ls -l /etc/speech-dispatcher/modules/
   spd-say -o espeak-ng "module test" || echo "module invocation failed"
   journalctl --user -u speech-dispatcher -n 30 --no-pager
   ```

10. Limpieza:

    ```bash
    spd-say -C
    rm -f /tmp/sample.wav /tmp/festival.wav
    ```

**Comprobá lo aprendido**

- **Q6.1** ¿Por qué Orca habla con Speech Dispatcher en lugar de llamar a `espeak-ng` directamente? Dá dos beneficios concretos.
- **Q6.2** `espeak-ng "test"` se escucha pero `spd-say "test"` es mudo. Nombrá tres comprobaciones, en orden.
- **Q6.3** Enunciá la diferencia arquitectónica entre espeak-ng y Festival, y la situación en la que cada uno es la elección correcta.
- **Q6.4** ¿Qué archivo fija el sintetizador por defecto para todos los usuarios, y qué archivo lo sobrescribe para uno solo?
- **Q6.5** ¿Qué produce `espeak-ng -x -q` y cuándo lo usarías realmente en un caso de soporte?

---

## Bloque 7 — Orca, el lector de pantalla de GNOME

**Objetivo:** arrancar, configurar y diagnosticar Orca, y ubicarlo correctamente en el stack: Orca consume **AT-SPI2** (Bloque 2) y emite a través de **Speech Dispatcher** (Bloque 6) y/o **BrlAPI** (Bloque 8).

1. Confirmá los prerrequisitos antes de lanzar nada:

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   pgrep -a at-spi2-registryd
   spd-say "speech backend alive"
   ```

2. Arrancá Orca en primer plano con el registro visible, para que los fallos no sean silenciosos:

   ```bash
   orca --replace --debug-file=/tmp/orca-debug &
   sleep 3
   pgrep -a orca
   ```

   *(`--replace` mata una instancia existente; sin él, un segundo lanzamiento simplemente sale.)*

3. Abrí el diálogo de preferencias. Desde el teclado, es `modificador Orca`+`Space`:

   ```bash
   orca --setup &
   ```

   El **modificador Orca** es `Insert` en la disposición de teclado de *escritorio* y `CapsLock` en la de *laptop* — configurá esto en Preferencias → Teclado, porque todos los demás atajos de Orca se construyen sobre él.

4. Practicá los comandos centrales en un editor de texto (`Orca` abajo significa la tecla modificadora):

   | Teclas | Acción |
   |---|---|
   | `Orca`+`Space` | Preferencias |
   | `Orca`+`H` | Modo aprendizaje (anuncia las teclas en vez de actuar) — `Esc` para salir |
   | `Orca`+`KP_Add` | Decir todo (leer el documento entero) |
   | `Orca`+`KP_Enter` | Dónde estoy (contexto: ventana, widget, selección) |
   | `Orca`+`S` | Conmutar la voz |
   | `Orca`+`F11` | Conmutar el modo de lectura de tablas |
   | `Orca`+`Q` | Salir de Orca |

5. Inspeccioná la configuración persistida. Orca moderno guarda JSON bajo XDG data:

   ```bash
   ls -l ~/.local/share/orca/
   python3 -m json.tool ~/.local/share/orca/user-settings.conf | head -30
   ```

   ```
   {
       "general": {
           "speechServerFactory": "orca.speechdispatcherfactory",
           "enableSpeech": true,
           "enableBraille": false,
           "keyboardLayout": 1,
           "verbalizePunctuationStyle": 1
   ...
   ```

6. Hacé que Orca arranque automáticamente para este usuario — la forma nativa del escritorio y la genérica:

   ```bash
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
   # generic XDG autostart, works under any desktop:
   mkdir -p ~/.config/autostart
   cp /usr/share/applications/orca.desktop ~/.config/autostart/ 2>/dev/null || \
   cat > ~/.config/autostart/orca.desktop <<'EOF'
   [Desktop Entry]
   Type=Application
   Name=Orca Screen Reader
   Exec=orca
   X-GNOME-Autostart-Phase=Applications
   EOF
   ```

7. Verificá que el atajo de conmutación funcione sin ratón: `Super`+`Alt`+`S` conmuta el lector de pantalla en GNOME. Confirmá el enlace:

   ```bash
   gsettings get org.gnome.settings-daemon.plugins.media-keys screenreader
   ```

8. Diagnosticá un Orca mudo recorriendo el stack hacia abajo:

   ```bash
   grep -iE 'error|traceback|exception' /tmp/orca-debug* | head
   pgrep -a at-spi2-registryd || echo "AT-SPI registry not running -> nothing to read"
   spd-say "dispatcher"          || echo "speech backend broken -> Orca has no voice"
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   ```

9. Detené Orca y deshacé el arranque automático:

   ```bash
   orca --quit || pkill -f '/usr/bin/orca'
   rm -f ~/.config/autostart/orca.desktop
   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false
   ```

**Comprobá lo aprendido**

- **Q7.1** Orca está corriendo, `at-spi2-registryd` está corriendo, `spd-say` funciona, y Orca sigue sin decir nada cuando enfocás widgets. ¿Cuál es el único ajuste principal sospechoso?
- **Q7.2** ¿Por qué Orca ofrece dos disposiciones de teclado, y cuál es la consecuencia práctica de elegir "laptop"?
- **Q7.3** Nombrá las tres interfaces entre las que se sitúa Orca, una por dirección.
- **Q7.4** ¿Qué resuelve `orca --replace` que `orca` a secas no?
- **Q7.5** La lista de objetivos también menciona GOK y emacspeak. ¿Qué es cada uno, y por qué no desplegarías GOK en un sistema actual?

---

## Bloque 8 — Braille: BRLTTY, BrlAPI y xbrlapi

**Objetivo:** configurar una línea braille actualizable de punta a punta. BRLTTY es un **daemon** que renderiza el contenido de la pantalla a un dispositivo braille; maneja la consola de texto de Linux de forma nativa y alcanza las aplicaciones gráficas a través de AT-SPI2. Referencia: <https://brltty.app/>

1. Establecé qué está instalado y qué drivers soporta el binario:

   ```bash
   brltty --version
   brltty --help | head -40
   ls /usr/lib/brltty/libbrl*.so 2>/dev/null || ls /usr/lib*/brltty/libbrl*.so
   ```

   ```
   ...libbrlxal.so  libbrlxbm.so  libbrlxbn.so  libbrlxeu.so  libbrlxfs.so
   libbrlxht.so  libbrlxpm.so  libbrlxsk.so  libbrlxvo.so ...
   ```

   Cada `libbrl<XX>.so` es un código de driver braille de dos letras (`ht` = Handy Tech, `pm` = Papenmeier, `bm` = Baum, `al` = Alva, …). `auto` los sondea.

2. Leé el archivo de configuración principal. Cada directiva de acá tiene una opción de línea de comandos equivalente:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/brltty.conf
   ```

   ```
   braille-driver      auto
   braille-device      usb:
   text-table          en_US
   ```

3. Entendé los cuatro ejes de driver que expone BRLTTY, y después fijalos explícitamente:

   | Eje | Opción | Valores de ejemplo |
   |---|---|---|
   | Driver braille (el hardware) | `-b` / `braille-driver` | `auto`, `ht`, `al`, `pm`, `no` |
   | Dispositivo braille (el transporte) | `-d` / `braille-device` | `usb:`, `serial:/dev/ttyS0`, `bluetooth:AA:BB:…` |
   | Tabla de texto (carácter → patrón de puntos) | `-t` / `text-table` | `en_US`, `es`, `de`, `auto` |
   | Screen driver (de dónde viene el texto) | `-x` / `screen-driver` | `lx` (consola Linux), `a2` (AT-SPI2) |

   ```bash
   sudo cp /etc/brltty.conf /etc/brltty.conf.bak
   sudo tee -a /etc/brltty.conf >/dev/null <<'EOF'
   braille-driver      auto
   braille-device      usb:
   text-table          en_US
   contraction-table   en-us-g2
   api-parameters      Auth=/etc/brlapi.key
   EOF
   ```

4. Ejecutá BRLTTY en primer plano con registro de depuración — la única forma confiable de ver el sondeo de dispositivos:

   ```bash
   sudo systemctl stop brltty
   sudo brltty -n -e -l debug -b auto -d usb: -t en_US
   ```

   * `-n` no pasar a segundo plano, `-e` registrar a stderr, `-l debug` verbosidad máxima.
   * Sin una línea conectada verás fallar el sondeo — ese texto de fallo *es* el ejercicio: leé qué drivers se probaron y sobre qué dispositivo.

5. Inspeccioná el servicio y la activación por udev. BRLTTY normalmente lo arranca udev cuando se enchufa una línea conocida, no en el arranque del sistema:

   ```bash
   systemctl status brltty.service
   systemctl list-units 'brltty*'
   grep -h -m5 'brltty' /usr/lib/udev/rules.d/*brltty*.rules
   udevadm monitor --udev --subsystem-match=usb    # then plug the display in
   ```

6. Simulá una línea sin hardware. El driver `xw` renderiza una ventana braille en pantalla, lo que te permite validar tablas y disposición:

   ```bash
   sudo brltty -n -e -l info -b xw -d none -t en_US
   ```

7. Explorá las herramientas de tablas — `.ttb` son tablas de texto, `.ctb` tablas de contracción, `.ktb` tablas de teclas:

   ```bash
   ls /etc/brltty/Text/ | head
   ls /etc/brltty/Contraction/ | head
   brltty-ttb -h 2>&1 | head -5      # text table compiler/converter
   brltty-ktb -h 2>&1 | head -5      # key table lister
   ```

8. Configurá **BrlAPI**, el protocolo cliente que permite a otros programas (Orca, editores) escribir en la línea a través de BRLTTY en lugar de disputarle el dispositivo:

   ```bash
   sudo ls -l /etc/brlapi.key
   sudo setfacl -m u:"$USER":r /etc/brlapi.key   # or add yourself to the brlapi group
   getent group brlapi
   ```

9. Puenteá la sesión gráfica. `xbrlapi` le informa a BRLTTY del foco de X para que la línea siga a la ventana activa:

   ```bash
   xbrlapi --quiet &
   pgrep -a xbrlapi
   ```

   Para una sesión GNOME/AT-SPI, el equivalente es ejecutar BRLTTY con el screen driver AT-SPI2:

   ```bash
   sudo brltty -n -e -b xw -d none -x a2
   ```

10. Habilitá la salida braille en Orca y confirmá que los dos se están hablando:

    ```bash
    python3 -c "import brlapi; b=brlapi.Connection(); print(b.driverName, b.displaySize)"
    ```

    ```
    b'XWindow' (40, 1)
    ```

11. Restauración:

    ```bash
    sudo pkill -f 'brltty -n'; pkill xbrlapi
    sudo mv /etc/brltty.conf.bak /etc/brltty.conf
    sudo systemctl start brltty
    ```

**Comprobá lo aprendido**

- **Q8.1** ¿Por qué BRLTTY necesita un *screen driver*, y qué cambia entre `lx` y `a2`?
- **Q8.2** Una línea braille funciona en la consola de texto pero no muestra nada en la sesión GNOME. Dá las dos soluciones posibles.
- **Q8.3** ¿Qué es BrlAPI, y qué problema concreto resuelve que el acceso directo al dispositivo no resuelve?
- **Q8.4** Explicá la diferencia entre una tabla de texto y una tabla de contracción, y por qué `en-us-g2` no es un ajuste de idioma.
- **Q8.5** `systemctl status brltty` muestra el servicio inactivo, y sin embargo la línea del usuario funciona. ¿Cómo?
- **Q8.6** Estás depurando una línea que nunca se detecta. Escribí el comando exacto que ejecutás primero y justificá cada flag.

---

## Bloque 9 — Teclados en pantalla y alternativas de puntero

**Objetivo:** proveer entrada de texto y apuntado para un usuario que no puede usar un teclado o un ratón físicos.

1. Lanzá **Onboard**, el teclado en pantalla GTK mantenido, e inspeccioná su esquema de configuración:

   ```bash
   onboard &
   gsettings list-schemas | grep -i onboard
   gsettings set org.onboard layout '/usr/share/onboard/layouts/Full Keyboard.onboard'
   gsettings set org.onboard theme  '/usr/share/onboard/themes/HighContrast.theme'
   gsettings set org.onboard.window transparent-background false
   ```

2. Encendé el teclado en pantalla integrado del escritorio, que es a lo que se refiere el interruptor "screen keyboard" del objetivo en GNOME:

   ```bash
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
   ```

3. Usá **xvkbd**, el teclado virtual X mínimo, y — más útil aún — su modo de scripting, que inyecta pulsaciones vía la extensión XTEST:

   ```bash
   xvkbd -no-jump-pointer &
   xvkbd -text 'ls -l\n'            # types into the focused window
   xvkbd -window Terminal -text 'echo injected\n'
   ```

4. Compará con `xdotool`, el driver XTEST de propósito general usado para scriptear entrada asistiva:

   ```bash
   xdotool getactivewindow getwindowname
   xdotool type --delay 120 'typed by xdotool'
   xdotool key ctrl+alt+t
   xdotool mousemove 400 300 click 1
   ```

5. Reactivá **Mouse Keys** del Bloque 3 y combinalo con el clic por permanencia del Bloque 4 para producir un puntero completamente manejado por teclado:

   ```bash
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-enable true
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-max-speed 400
   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-init-delay 200
   gsettings set org.gnome.desktop.a11y.mouse dwell-click-enabled true
   ```

6. Inspeccioná **gestos / dispositivos de puntero** al nivel del driver de entrada, donde viven el tap-to-click, el drag-lock y el modo para zurdos:

   ```bash
   xinput list
   xinput list-props "$(xinput list --name-only | grep -i -m1 touchpad)"
   ```

   ```
   Device 'SynPS/2 Synaptics TouchPad':
       libinput Tapping Enabled (322):  1
       libinput Tapping Drag Lock Enabled (326):  0
       libinput Left Handed Enabled (300):  0
       libinput Accel Speed (293):  0.000000
   ```

   ```bash
   gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
   gsettings set org.gnome.desktop.peripherals.mouse left-handed true
   gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'flat'
   ```

7. Revertí:

   ```bash
   pkill onboard; pkill xvkbd
   gsettings reset org.gnome.desktop.peripherals.mouse left-handed
   gsettings reset-recursively org.gnome.desktop.a11y.mouse
   gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false
   ```

**Comprobá lo aprendido**

- **Q9.1** ¿Cómo hace un teclado en pantalla para entregar una pulsación a una aplicación que cree que vino del hardware?
- **Q9.2** GOK figura en los objetivos de LPI. ¿Qué lo reemplazó, y qué deberías instalar realmente hoy?
- **Q9.3** Un usuario puede mover el puntero con Mouse Keys pero no puede hacer clic. Nombrá dos formas independientes de darle un clic.
- **Q9.4** ¿Por qué `xvkbd -text` no llega a una aplicación Wayland nativa mientras sigue funcionando contra una XWayland?

---

## Bloque 10 — Accesibilidad de la consola de texto

**Objetivo:** aplicar los mismos cuatro ejes — contraste, tamaño, temporización del teclado, voz — a un sistema sin ningún servidor X. Ésta es la parte que los candidatos más suelen saltear y la que importa en un servidor headless.

1. Cambiá a una consola de texto (`Ctrl`+`Alt`+`F3`) e identificá la fuente de consola y el mapa de teclado actuales:

   ```bash
   setfont -O /tmp/current-font.psf 2>/dev/null; ls -l /tmp/current-font.psf
   cat /etc/vconsole.conf 2>/dev/null            # systemd distributions
   cat /etc/default/console-setup 2>/dev/null    # Debian/Ubuntu
   ```

   ```
   KEYMAP=us
   FONT=eurlatgr
   ```

2. Aplicá una **fuente de consola de letra grande**. Terminus trae tamaños de hasta 32 píxeles, en variantes negrita:

   ```bash
   ls /usr/share/kbd/consolefonts/ 2>/dev/null || ls /usr/share/consolefonts/
   sudo setfont ter-v32b            # 32-px bold Terminus
   sudo setfont ter-v16n            # back to something normal
   ```

3. Hacela persistente — el mecanismo difiere según la familia de la distribución:

   ```bash
   # systemd (Fedora, RHEL, Arch, openSUSE)
   sudo sed -i 's/^FONT=.*/FONT=ter-v32b/' /etc/vconsole.conf || \
       echo 'FONT=ter-v32b' | sudo tee -a /etc/vconsole.conf

   # Debian / Ubuntu
   sudo sed -i -e 's/^FONTFACE=.*/FONTFACE="Terminus"/' \
               -e 's/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup
   sudo setupcon
   ```

4. Ajustá el **contraste y los colores de la consola** con `setterm`, y evitá que la consola se apague sobre un usuario que lee despacio:

   ```bash
   setterm --foreground yellow --background black --store
   setterm --bold on
   setterm --blank 0 --powersave off
   setterm --cursor on
   setterm --default          # revert
   ```

5. Ajustá la **repetición de teclas en consola**, la contraparte de `xset r rate`:

   ```bash
   kbdrate                       # show current
   sudo kbdrate -d 1000 -r 5     # 1000 ms delay, 5 repeats/second
   sudo kbdrate -d 250 -r 30     # typical default
   ```

6. Inspeccioná y modificá el **mapa de teclado de la consola**, que es donde se puede remapear una tecla para un usuario que escribe con una sola mano:

   ```bash
   dumpkeys | head -20
   dumpkeys --keys-only | grep -i 'keycode  58'      # CapsLock
   sudo loadkeys <<'EOF'
   keycode 58 = Control
   EOF
   sudo loadkeys us                                   # restore
   ```

7. Controlá los LEDs del teclado, que es la forma de dar retroalimentación estilo Toggle Keys sin un escritorio:

   ```bash
   setleds -v
   sudo setleds +num -caps
   ```

8. Configurá **Speakup**, el lector de pantalla de consola dentro del kernel, puenteado a Speech Dispatcher por `speechd-up`:

   ```bash
   sudo modprobe speakup_soft
   ls /sys/accessibility/speakup/
   ls -l /dev/softsynth
   sudo systemctl start speechd-up 2>/dev/null || sudo speechd-up
   ```

   ```
   attributes  characters  i18n  keymap  soft  ...
   punc_level  rate  version  vol  synth  pitch
   ```

   ```bash
   cat /sys/accessibility/speakup/synth
   echo 5 | sudo tee /sys/accessibility/speakup/rate
   ```

   Para cargarlo en el arranque en su lugar: agregá `speakup.synth=soft` a la línea de comandos del kernel.

9. Apuntá BRLTTY a la consola explícitamente, que es su modo nativo y más simple:

   ```bash
   sudo brltty -n -e -l info -b xw -d none -x lx -t en_US
   ```

10. Revertí:

    ```bash
    setterm --default; sudo kbdrate -d 250 -r 30; sudo setfont ter-v16n
    sudo modprobe -r speakup_soft 2>/dev/null
    ```

**Comprobá lo aprendido**

- **Q10.1** Un administrador ciego debe usar un servidor headless por consola serie. ¿Cuáles dos de las herramientas de este bloque son relevantes, y cuáles son inútiles?
- **Q10.2** ¿Qué archivo hace que una fuente de consola sobreviva a un reinicio en una distribución systemd, y cuál en Debian?
- **Q10.3** ¿Cuál es el equivalente en consola de `xset r rate 660 25`, y por qué no lo puede ejecutar un usuario sin privilegios?
- **Q10.4** Speakup es un módulo del kernel mientras que Orca es un programa Python. ¿Qué se sigue de esa diferencia en cuanto a *cuándo* puede empezar a hablar cada uno?
- **Q10.5** `setterm --store` — ¿qué guarda exactamente, y cuánto sobrevive?

---

## Bloque 11 — Ejercicio de diagnóstico: un stack de accesibilidad roto

**Objetivo:** te entregan una estación de trabajo con el reporte *"el lector de pantalla dejó de funcionar después de la actualización"*. Recorré el stack de arriba hacia abajo y producí un veredicto en cada capa.

1. **Capa 0 — sesión.** ¿Las herramientas que estás por usar son siquiera aplicables?

   ```bash
   echo "$XDG_SESSION_TYPE"; echo "$XDG_CURRENT_DESKTOP"
   ```

2. **Capa 1 — la aplicación asistiva.** ¿Está corriendo, y registra algo?

   ```bash
   pgrep -a orca || echo 'VERDICT: Orca is not running'
   orca --replace --debug-file=/tmp/orca-diag &
   sleep 4; grep -icE 'error|exception' /tmp/orca-diag*
   ```

3. **Capa 2 — el interruptor del escritorio.** ¿El escritorio cree que el lector de pantalla debería estar encendido?

   ```bash
   gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled
   ```

4. **Capa 3 — el puente del toolkit.** ¿Las aplicaciones están exportando algo para leer?

   ```bash
   gsettings get org.gnome.desktop.interface toolkit-accessibility
   env | grep -E 'NO_AT_BRIDGE|GTK_MODULES|QT_ACCESSIBILITY'
   ```

5. **Capa 4 — el bus de accesibilidad.** ¿Está vivo y alcanzable el transporte?

   ```bash
   pgrep -a at-spi2-registryd at-spi-bus-launcher
   gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
              --method org.a11y.Bus.GetAddress
   python3 -c "import pyatspi; print(pyatspi.Registry.getDesktop(0).childCount, 'apps on the bus')"
   ```

6. **Capa 5 — el backend de salida.** ¿Puede algo emitir sonido o manejar la línea braille?

   ```bash
   spd-say "backend test" || echo 'VERDICT: speech-dispatcher path is broken'
   espeak-ng "synthesizer test" || echo 'VERDICT: synthesizer itself is broken'
   speaker-test -t sine -f 440 -l 1 || echo 'VERDICT: audio device is broken'
   ```

7. **Capa 6 — lado de entrada.** ¿Las funciones AccessX están peleando contra el usuario en vez de ayudarlo?

   ```bash
   xkbset q | grep -E 'On - (SlowKeys|BounceKeys|StickyKeys|MouseKeys)'
   gsettings list-recursively org.gnome.desktop.a11y.keyboard | grep 'true$'
   ```

8. Escribí el veredicto como una sola línea que nombre la capa **más baja** que falló, y después arreglá sólo esa capa y volvé a probar hacia arriba.

**Comprobá lo aprendido**

- **Q11.1** ¿Por qué de arriba hacia abajo es el orden equivocado para *arreglar*, aunque sea un orden razonable para *observar*?
- **Q11.2** La capa 4 reporta 0 aplicaciones en el bus pero el escritorio está lleno de ventanas. ¿Qué capa tiene la culpa realmente?
- **Q11.3** El usuario dice que "el teclado se volvió inusable" un día después de que activaras funciones de accesibilidad. ¿Qué único comando reproduce la causa más probable?
- **Q11.4** Todo en las capas 0–5 pasa y Orca sigue mudo. Nombrá los dos sospechosos restantes.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**Q1.1** O bien (a) `DISPLAY` no está definida o es incorrecta — estás en una consola de texto, en una sesión SSH sin reenvío de X, o en un servicio systemd con un entorno limpio; o (b) estás en una sesión **Wayland**, donde no hay un servidor X escuchando para `xkbset` de la forma en que éste espera (sólo XWayland lo está, y no acepta control AccessX de clientes arbitrarios como sí lo hace un servidor X clásico). Distinguí con `echo "$XDG_SESSION_TYPE"` — `x11` frente a `wayland` — contrastado con `echo $DISPLAY`. Si el tipo es `x11` y `DISPLAY` está vacía, es (a); si el tipo es `wayland`, es (b).

**Q1.2** El **bus launcher** está roto. `at-spi-bus-launcher` arranca y es dueño del daemon D-Bus privado de accesibilidad y publica su dirección (`org.a11y.Bus.GetAddress`, más la propiedad `AT_SPI_BUS` de la ventana raíz bajo X). `at-spi2-registryd` es el *registro* que corre **sobre** ese bus: las aplicaciones registran ahí sus árboles accesibles y las herramientas asistivas descubren aplicaciones a través de él. Un registro sin un bus por debajo no tiene transporte, así que ninguna aplicación puede registrarse y ningún lector de pantalla puede descubrir nada.

**Q1.3** Porque los esquemas vienen en el paquete `gsettings-desktop-schemas`, que es una dependencia de muchos componentes no-GNOME (aplicaciones GTK, `at-spi2-core`, el propio Orca). Que el esquema esté *instalado* sólo significa que la clave se puede leer y escribir; no dice nada sobre si algún proceso está escuchando los cambios. En Plasma, escribir `org.gnome.desktop.a11y.keyboard stickykeys-enable true` cambiará el valor almacenado y no cambiará nada en pantalla, porque `gnome-settings-daemon` no está corriendo para actuar en consecuencia.

**Q1.4** Inútiles (o degradadas a sólo-XWayland) bajo Wayland: `xkbset`, `xvkbd`, `xdotool`, `xzoom`, `xmag`, `xbrlapi`, y las partes específicas de X de `xset`/`xprop`/`xev`. Sigue plenamente funcional porque nunca toca el servidor gráfico: **`espeak-ng`** (igual que `festival` y `spd-say` — sólo necesitan un dispositivo de audio). `setfont`, `setterm` y `kbdrate` tampoco se ven afectados, pero actúan sobre la consola de texto y no sobre la sesión gráfica.

### Bloque 2

**Q2.1** Aislamiento, volumen y ciclo de vida. El tráfico de accesibilidad es de alta frecuencia — cada cambio de foco, cada movimiento del cursor de texto y cada inserción de texto generan señales — y ponerlo en el bus de sesión compartido lo inundaría y además expondría el árbol de widgets de toda aplicación a cualquier cliente del bus de sesión. Un bus dedicado también permite que el stack de accesibilidad exista en contextos que no tienen un bus de sesión ordinario (una pantalla de login, por ejemplo), y que se arranque y detenga con independencia del resto de la sesión.

**Q2.2** En orden de probabilidad: (1) el puente del toolkit de la aplicación no está cargado — `toolkit-accessibility` está en false, o `NO_AT_BRIDGE=1` está definida en su entorno; (2) el toolkit no tiene soporte AT-SPI en absoluto — una aplicación X11/SDL/Electron-con-accesibilidad-deshabilitada dibuja píxeles y no exporta nada; (3) el bus mismo es inalcanzable desde ese proceso — se lanzó desde otra sesión, un contenedor o una unidad systemd con el entorno depurado, de modo que no puede resolver `org.a11y.Bus`.

**Q2.3** `toolkit-accessibility=false` es un ajuste de *política* leído desde dconf en la inicialización del toolkit; se aplica a las aplicaciones recién iniciadas en esa sesión y se puede conmutar de forma centralizada. `NO_AT_BRIDGE=1` es una *anulación de entorno* por proceso que impide incondicionalmente que GTK cargue el puente ATK, sin importar el valor de GSettings, y sólo afecta a los procesos que la heredan. En la práctica: la clave GSettings es cómo configurás un escritorio; la variable de entorno es cómo excluís una aplicación o esquivás un puente que crashea.

**Q2.4** `QT_ACCESSIBILITY=1` (y en algunas compilaciones `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`). GTK no se ve afectado porque los dos toolkits llevan implementaciones de puente independientes: GTK3/4 incorporan el puente ATK/AT-SPI y lo condicionan a `toolkit-accessibility`/`NO_AT_BRIDGE`, mientras que Qt condiciona su propio puente a la variable `QT_ACCESSIBILITY`. Mismo bus, dos implementaciones de cliente separadas, dos interruptores separados.

### Bloque 3

**Q3.1** **Slow Keys**: una tecla debe mantenerse presionada durante un retardo configurado antes de que la pulsación se acepte — descarta las teclas rozadas accidentalmente al pasar, y sirve a usuarios con poca precisión motriz o temblor que a menudo rozan teclas vecinas. **Bounce Keys**: después de aceptar una tecla, se ignoran nuevas pulsaciones *de esa misma tecla* durante un intervalo configurado — descarta repeticiones involuntarias por temblor o espasticidad.

**Q3.2** Venció el **timeout de AccessX**. XKB apaga las funciones AccessX automáticamente tras un período sin actividad de teclado/puntero, para que una función activada accidentalmente no deje afuera al usuario. La solución es `xkbset exp` — declarar las funciones que deben conservar su estado cuando se dispare el timeout (por ejemplo `xkbset exp '=mousekeys' '=mousekeysaccel'`), o fijar el timeout de modo que nunca se dispare. Verificá la sintaxis exacta con `man 1 xkbset`, y después confirmá el resultado en el bloque *Access X Timeout* de `xkbset q`.

**Q3.3** Porque viven en partes distintas del protocolo X. El retardo y la tasa de autorrepetición son **controles de teclado del núcleo**, presentes desde X11R1 y manipulados por `xset r rate`. Sticky/Slow/Bounce/Mouse Keys son **controles AccessX**, definidos por la extensión XKB y manipulados a través de `XkbSetControls`, para lo cual `xkbset` es el front end CLI. `xset` es anterior a XKB y nunca se extendió para cubrirlo.

**Q3.4** `twokey` ("presionar dos teclas simultáneamente deshabilita Sticky Keys") y `latchlock`. El usuario está presionando sin querer dos teclas a la vez, que es precisamente el patrón de entrada que Sticky Keys existe para evitar, así que la válvula de seguridad se dispara constantemente. Neutralizalo con `xkbset sticky -twokey -latchlock`; en la capa de escritorio el equivalente es `gsettings set org.gnome.desktop.a11y.keyboard stickykeys-two-key-off false`.

**Q3.5** Con `latchlock` habilitado, la primera pulsación *retiene* (latch) el modificador sólo para la próxima pulsación; la segunda pulsación lo *bloquea* hasta que se lo presione una tercera vez para liberarlo. Eso es lo que permite tipear una serie de mayúsculas sin mantener Shift. Con `-latchlock`, la segunda pulsación simplemente cancela la retención.

**Q3.6** `xset -r <keycode>` deshabilita la autorrepetición para ese keycode solamente (`xset r <keycode>` la vuelve a habilitar). Obtené el keycode ejecutando `xev -event keyboard`, presionando la tecla, y leyendo el campo `keycode NN` del evento `KeyPress` — o con `xmodmap -pke | grep -i <keysym>`.

### Bloque 4

**Q4.1** El **interruptor maestro** `org.gnome.desktop.a11y.keyboard enable` está en `false`. Condiciona todo el grupo AccessX: con él apagado, las claves individuales `*-enable` se almacenan pero nunca se empujan hacia abajo a XKB. Ejecutá `gsettings set org.gnome.desktop.a11y.keyboard enable true`. (Segundo candidato, si eso ya está en true: no hay ningún settings daemon corriendo que traduzca la clave en una llamada `XkbSetControls` — ver Q4.3.)

**Q4.2** `gsettings` es el front end de línea de comandos de la API **GSettings**; **dconf** es el backend que GSettings usa en Linux. El valor se guarda en una base de datos binaria, mapeada en memoria, en `~/.config/dconf/user` para los ajustes por usuario, con los valores por defecto de todo el sistema compilados desde `/etc/dconf/db/*.d/` hacia `/etc/dconf/db/*`. El *esquema* — nombres de claves, tipos, valores por defecto, rangos — es un archivo compilado aparte en `/usr/share/glib-2.0/schemas/gschemas.compiled`. Escribir una clave que no tiene esquema falla; por eso `gsettings` rechaza claves desconocidas mientras que `dconf write` no.

**Q4.3** Que ningún proceso está escribiendo esas claves — el panel en el que estás haciendo clic no está respaldado por GSettings, o `gnome-settings-daemon` / GNOME Shell no está corriendo (estás en otro escritorio que guarda sus ajustes de accesibilidad en otro lado, p. ej. Plasma en `~/.config/kaccessrc`). Confirma que la ruta del esquema de GNOME es un callejón sin salida en esa máquina.

**Q4.4** A nivel del servidor X, el **control XKB es autoritativo** — es el estado real en tiempo de ejecución, y `xkbset` lo escribe directamente. La clave GSettings es el estado *deseado*, y el settings daemon reconcilia a ambos. En consecuencia, cuando `gnome-settings-daemon` arranca, se reinicia, u observa un cambio en el esquema a11y, vuelve a aplicar su propia visión y **sobrescribe tu cambio de `xkbset`**. Por eso el ajuste manual con `xkbset` es estable en un gestor de ventanas pelado y transitorio bajo un escritorio completo.

**Q4.5** Con una **base de datos de sistema de dconf**: creá `/etc/dconf/db/local.d/00-a11y` con

```ini
[org/gnome/desktop/a11y/keyboard]
enable=true
stickykeys-enable=true
```

asegurate de que `/etc/dconf/profile/user` contenga `user-db:user` seguido de `system-db:local`, y después ejecutá `sudo dconf update`. Agregá un archivo `/etc/dconf/db/local.d/locks/a11y` correspondiente que liste las rutas de las claves si el ajuste debe ser obligatorio en vez de un valor por defecto.

### Bloque 5

**Q5.1** `text-scaling-factor` multiplica el tamaño de **todo el texto** del escritorio dejando intactas la geometría de los widgets, los iconos y el gestor de ventanas — éste es el control de accesibilidad ("Texto grande"). `font-name 'Cantarell 16'` cambia sólo la **fuente de interfaz por defecto**, de modo que las aplicaciones que especifican su propia fuente no se ven afectadas y el escalado del texto queda inconsistente en el resto. Un `scaling-factor` de pantalla (HiDPI) es un **multiplicador entero para toda la salida renderizada** — texto, iconos, widgets, cursores — pensado para corregir la densidad de píxeles, no para baja visión, y típicamente sólo acepta números enteros.

**Q5.2** (1) ¿Está el tema realmente instalado — `ls -d /usr/share/themes/HighContrast`? La clave guarda una cadena arbitraria y no reporta error para un tema inexistente. (2) ¿Hay algo leyendo la clave — está corriendo `gnome-settings-daemon`/GNOME Shell, y tu versión de GNOME espera en cambio `org.gnome.desktop.a11y.interface high-contrast`? Comprobalo con `gsettings list-keys org.gnome.desktop.a11y.interface` y `dconf watch`.

**Q5.3** Porque una magnificación útil debe **seguir el punto de interés**, no sólo el puntero. Para mantener el cursor de texto, el widget enfocado o el ítem que un lector de pantalla está anunciando dentro del área magnificada, el magnificador se suscribe a los eventos de foco y de movimiento del cursor de AT-SPI — el mismo flujo de eventos que consume Orca. Sin AT-SPI sólo puede hacer seguimiento del ratón, y por eso `xzoom` es estrictamente menos útil que el magnificador del escritorio para un usuario de teclado.

**Q5.4** `full-screen` magnifica toda la pantalla: la pantalla entera se vuelve un área ampliada que se desplaza a medida que el foco se mueve, y no queda ningún contexto sin magnificar. `lens-mode` renderiza una **ventana magnificada que sigue al puntero** sobre un escritorio por lo demás sin magnificar, preservando el contexto circundante a tamaño normal. La pantalla completa conviene para baja visión severa; el modo lente conviene a usuarios que necesitan ampliación ocasional conservando la orientación espacial.

**Q5.5** `xzoom` (continuo, sigue al puntero) y `xmag` (magnificación de instantánea única); `kmag` si las bibliotecas de KDE son aceptables. La limitación es que son magnificadores X de píxeles puros sin integración AT-SPI: sólo siguen al ratón, así que el foco de teclado y el movimiento del cursor de texto no arrastran el área ampliada, y bajo Wayland o bien fallan o bien sólo ven superficies XWayland.

### Bloque 6

**Q6.1** (1) **Arbitraje y prioridad**: varios clientes (Orca, un daemon de notificaciones, un lector de terminal) pueden pedir voz al mismo tiempo; Speech Dispatcher encola, interrumpe y prioriza mensajes (`important`, `message`, `text`, `notification`, `progress`) para que una alerta urgente se abra paso en medio de la lectura de un documento largo. (2) **Independencia del sintetizador**: Orca pide "decí esto, a esta velocidad, en este idioma" y Speech Dispatcher lo enruta al módulo de salida para el que el sistema esté configurado — espeak-ng, Festival, un motor comercial — de modo que cambiar de voz no requiere ningún cambio en Orca. Beneficios secundarios: ajustes consistentes de velocidad/tono/volumen por usuario en todos los clientes, y un solo proceso dueño del dispositivo de audio en lugar de muchos.

**Q6.2** (1) ¿Está el daemon de Speech Dispatcher corriendo y alcanzable — `systemctl --user status speech-dispatcher`, más `journalctl --user -u speech-dispatcher`? (2) ¿Hay un módulo de salida válido configurado y cargable — `spd-say -O` para listar, `DefaultModule` en `/etc/speech-dispatcher/speechd.conf` y cualquier anulación en `~/.config/speech-dispatcher/speechd.conf`, y `ls /etc/speech-dispatcher/modules/`? (3) ¿Es correcto el método de salida de audio — `AudioOutputMethod` (`pulse`, `alsa`, `pipewire`) puede apuntar a un subsistema que esta sesión no usa, que es el caso clásico donde el sintetizador funciona por su cuenta pero el daemon es mudo.

**Q6.3** **espeak-ng** es un sintetizador de *formantes*: genera voz a partir de un modelo acústico del tracto vocal, así que es diminuto (unos pocos MB), extremadamente rápido, soporta ~100 idiomas y es inteligible a velocidades de habla muy altas — pero suena robótico. **Festival** es un sistema *concatenativo / de selección de unidades*: pega fragmentos de voz grabados, así que necesita grandes bases de datos de voces, es más lento, cubre pocos idiomas y suena mucho más natural. Elegí espeak-ng para un lector de pantalla, donde dominan la latencia y la inteligibilidad a alta velocidad y los usuarios experimentados lo prefieren; elegí Festival para audio preparado, anuncios o cualquier cosa que un usuario vidente vaya a escuchar a velocidad normal.

**Q6.4** A nivel de sistema: `/etc/speech-dispatcher/speechd.conf` (`DefaultModule`). Por usuario: `~/.config/speech-dispatcher/speechd.conf`, generado y validado por `spd-conf`. El archivo del usuario se lee después del archivo del sistema y lo sobrescribe.

**Q6.5** `-x` imprime la **representación fonémica** que espeak-ng derivó del texto (`--ipa` la imprime en IPA), y `-q` suprime el audio. Lo usás cuando un usuario reporta que una palabra, sigla, nombre o unidad específica se pronuncia mal: el volcado de fonemas te dice si la culpa es de las reglas de pronunciación, de la entrada del diccionario o de la selección de idioma — y te da la cadena de fonemas exacta para poner en una entrada de diccionario personalizada.

### Bloque 7

**Q7.1** `org.gnome.desktop.interface toolkit-accessibility` está en `false` (o las aplicaciones que estás enfocando fueron lanzadas con `NO_AT_BRIDGE=1`). Todos los demás componentes están vivos, pero las aplicaciones no están exportando nada al bus, así que Orca no tiene nada que anunciar. La prueba confirmatoria es la enumeración con `pyatspi` del Bloque 2: una lista de escritorio vacía o casi vacía demuestra que el problema es el puente, no Orca.

**Q7.2** Porque la disposición de *escritorio* usa intensamente el **teclado numérico** — `KP_Add` para Decir todo, `KP_Enter` para Dónde estoy, el bloque numérico para la revisión plana — y una laptop no tiene teclado numérico. La disposición de laptop remapea esos comandos al bloque de teclas principal y cambia el **modificador Orca de `Insert` a `CapsLock`**. La consecuencia práctica de elegir laptop: `CapsLock` deja de conmutar mayúsculas de la forma normal, lo que sorprende a los usuarios que comparten la máquina, y toda referencia impresa de atajos escrita para la disposición de escritorio deja de aplicar.

**Q7.3** Aguas arriba, consume el escritorio a través de **AT-SPI2 sobre D-Bus** (qué hay en pantalla, qué tiene el foco, qué está haciendo el cursor de texto). Aguas abajo, emite a través de **Speech Dispatcher** (voz) y **BrlAPI** (braille), más señales de magnificación por el tercer lado. Su propia configuración y sus atajos de teclado quedan en el medio.

**Q7.4** Orca es un singleton: lanzar una segunda instancia mientras hay una corriendo normalmente sólo sale, y si una instancia previa está trabada o a medio morir te quedás sin lector de pantalla y sin ningún error que el usuario pueda percibir. `--replace` termina la instancia existente y toma el control de las conexiones a AT-SPI y a Speech Dispatcher, y por eso es la forma correcta de reiniciar Orca tras un cambio de configuración.

**Q7.5** **GOK** (GNOME On-screen Keyboard) era un teclado en pantalla dinámico, con barrido, para usuarios que sólo podían operar un pulsador o un puntero; no tiene mantenimiento y fue eliminado de las distribuciones actuales — instalá **Onboard** (o el teclado en pantalla integrado de GNOME Shell) en su lugar. **emacspeak** es un "escritorio de audio con voz": un conjunto de extensiones de Emacs que habla los búferes de Emacs directamente, dando un entorno auto-vocalizado completo para editar, correo, shell y navegación sin ninguna intervención de AT-SPI — sigue en uso activo y es un despliegue legítimo hoy.

### Bloque 8

**Q8.1** BRLTTY renderiza **texto**, no píxeles, así que necesita una fuente de texto más una posición de cursor — ése es el trabajo del screen driver. `lx` lee la consola virtual de Linux directamente (a través de `/dev/vcsa*`), obteniendo la grilla exacta de celdas de caracteres y la ubicación del cursor de una consola de texto. `a2` obtiene el contenido de las aplicaciones gráficas a través de **AT-SPI2**, reconstruyendo una vista textual del widget enfocado. El driver braille y el dispositivo no cambian; sólo cambia de dónde viene el texto.

**Q8.2** O bien (a) ejecutar `xbrlapi` en la sesión gráfica, para que la información de foco de X se le reporte a BRLTTY y la línea siga a la ventana activa; o (b) ejecutar BRLTTY con el screen driver AT-SPI2 (`-x a2` / `screen-driver a2` en `brltty.conf`) y dejar que un lector de pantalla como Orca maneje la salida braille por BrlAPI. Bajo Wayland sólo el segundo camino es viable.

**Q8.3** BrlAPI es el **protocolo cliente/servidor** que BRLTTY expone para que otros programas puedan escribir en la línea braille y leer sus teclas sin tocar el hardware. El problema que resuelve es el acceso exclusivo al dispositivo: sólo un proceso puede ser dueño de una línea braille serie/USB, así que sin BrlAPI, Orca y BRLTTY se disputarían el puerto y uno de los dos fallaría. Con BrlAPI, BRLTTY es dueño del dispositivo y multiplexa; Orca, los editores y las herramientas propias se vuelven clientes. La autenticación es por el secreto compartido en `/etc/brlapi.key`, y por eso tu usuario debe poder leer ese archivo.

**Q8.4** Una **tabla de texto** (`.ttb`) es un mapeo uno a uno de caracteres a patrones de celdas braille de 8 puntos — es lo que hace que `é` o `ñ` salgan correctamente para un idioma y un estándar braille dados. Una **tabla de contracción** (`.ctb`) implementa braille de *grado 2*, donde palabras comunes y grupos de letras se comprimen en menos celdas (`and`, `the`, `-ing` se vuelven cada uno una sola celda). `en-us-g2` no es entonces una selección de idioma sino una selección de **sistema de contracción**: dice "inglés de EE. UU., grado 2 contraído". Un usuario que lee braille sin contraer necesita la tabla de texto pero ninguna tabla de contracción, y forzarle una vuelve la salida ilegible.

**Q8.5** Porque BRLTTY normalmente lo arranca **udev** cuando se enchufa una línea reconocida, no el servicio persistente `brltty.service`. Las reglas de udev bajo `/usr/lib/udev/rules.d/` (típicamente `90-brltty.rules`) coinciden con el ID de fabricante/producto USB de la línea e instancian una unidad plantilla como `brltty@<device>.service`. `systemctl list-units 'brltty*'` revela la instancia; `systemctl status brltty.service` por sí solo no.

**Q8.6** `sudo brltty -n -e -l debug -b auto -d usb: -t en_US`, tras detener el servicio del paquete. `-n` lo mantiene en primer plano para que no se desprenda y esconda su salida; `-e` manda el registro a stderr, donde podés leerlo en vivo en vez de a syslog; `-l debug` sube la verbosidad para que aparezca cada sondeo de driver y cada byte del handshake; `-b auto` hace que pruebe por turno cada driver braille compilado, y el registro te dice entonces qué drivers se intentaron y cómo falló cada uno; `-d usb:` fija el transporte para que un fallo sea inequívocamente "no se encontró ninguna línea en USB" y no un repliegue a algún otro puerto.

### Bloque 9

**Q9.1** A través de la **extensión XTEST** (X11) — el cliente le pide al servidor X que sintetice un evento de tecla o botón, y el servidor lo inyecta en el flujo normal de eventos, de modo que la aplicación receptora no puede distinguirlo de una entrada de hardware real. `xvkbd -text`, `xdotool type` y la salida de teclas de Onboard funcionan todos así. La alternativa, usada por algunas herramientas y obligatoria bajo Wayland, es un **dispositivo de entrada virtual a nivel de kernel** creado con `uinput`, que inyecta en la capa evdev por debajo del servidor gráfico.

**Q9.2** GOK no tiene mantenimiento y ya no lo empaquetan las distribuciones actuales. Su rol fue asumido por **Onboard** (un teclado en pantalla GTK completo con predicción de palabras, modos de barrido y temas), por **Caribou** (la integración con GNOME Shell, a su vez ya en gran medida superada), y hoy por el **teclado en pantalla integrado de GNOME Shell**, habilitado con `org.gnome.desktop.a11y.applications screen-keyboard-enabled`. Instalá Onboard, o usá el teclado integrado del escritorio. Sabete el nombre de GOK para el examen; no lo despliegues.

**Q9.3** (1) Las propias teclas de clic de Mouse Keys: `5` en el teclado numérico hace clic, `+` hace doble clic, y `/ * -` seleccionan qué botón presionará `5` — probablemente la función esté funcionando y el usuario simplemente tenga NumLock en el estado equivocado o no le hayan enseñado las teclas. (2) **Clic por permanencia** — `org.gnome.desktop.a11y.mouse dwell-click-enabled true` con un `dwell-time` — que hace clic automáticamente cuando el puntero se queda quieto. Una tercera opción es un pulsador de hardware o `xdotool click 1` asociado a una tecla accesible.

**Q9.4** Porque Wayland elimina deliberadamente la capacidad de un cliente de inyectar entrada en otro: no hay un camino de inyección global equivalente a XTEST, y cada cliente sólo recibe los eventos que el compositor le enruta. Una aplicación XWayland sigue corriendo contra un servidor X real (el servidor XWayland), así que `xvkbd`/`xdotool` pueden usar XTEST contra ella — pero sólo para clientes X, y sólo dentro de esa instancia de XWayland. Los teclados en pantalla nativos de Wayland funcionan en cambio mediante protocolos del lado del compositor (`virtual-keyboard`, `input-method`) o mediante `uinput` por debajo del compositor.

### Bloque 10

**Q10.1** Relevantes: **BRLTTY** (con una línea braille; funciona nativamente en la consola y en dispositivos serie) y **Speakup** con `speechd-up` si la máquina tiene un dispositivo de audio — aunque en una consola serie realmente headless, el braille o una sesión SSH remota con Orca en el *cliente* es la respuesta realista. Inútiles: `setfont`, `setterm --foreground` y todo lo visual, porque atienden la baja visión y no la ceguera — y en una consola serie la fuente la renderiza el emulador de terminal del otro extremo, no el kernel, así que `setfont` no tiene ningún efecto.

**Q10.2** Distribuciones systemd: `/etc/vconsole.conf` (`FONT=`, y `KEYMAP=` para el mapa de teclado), aplicado por `systemd-vconsole-setup`. Debian/Ubuntu: `/etc/default/console-setup` (`FONTFACE=`, `FONTSIZE=`), aplicado por `setupcon` y el servicio `console-setup`.

**Q10.3** `kbdrate -d <delay_ms> -r <rate_per_second>`. Requiere privilegios porque no es una petición a un servidor de espacio de usuario sino un **ioctl contra el dispositivo de teclado / driver de consola del kernel** (`KDKBDREP` en la consola), que altera un ajuste global del kernel que afecta a todos los usuarios de todas las consolas virtuales — a diferencia de `xset`, que cambia el estado dentro de un servidor X que pertenece a una sesión.

**Q10.4** Speakup está compilado en el **kernel** o lo carga éste, así que puede hablar desde muy temprano en el arranque — durante el initramfs, en el pedido de contraseña de LUKS, en un shell de rescate, y en un sistema que nunca arranca una sesión gráfica. Orca es un programa Python que depende de un bus de sesión en marcha, de AT-SPI2 y de Speech Dispatcher, así que sólo puede hablar una vez que la sesión de escritorio está levantada. Para un administrador ciego esto es decisivo: Speakup (o BRLTTY) cubre arranque, recuperación y modo monousuario; Orca cubre sólo el escritorio.

**Q10.5** `--store` guarda el **color de primer plano y de fondo actuales de la consola** como los valores que restaurará un `setterm --default` o un `reset`. Es una propiedad en tiempo de ejecución de la consola del kernel, así que sobrevive hasta el reinicio pero **no a través de un reinicio** — persistir los colores de la consola requiere poner la llamada a `setterm` en un archivo de inicio como `/etc/profile.d/` o en una unidad systemd.

### Bloque 11

**Q11.1** Porque las capas son dependientes, no independientes: un fallo en una capa baja hace que toda capa por encima *parezca* rota, así que un arreglo de arriba hacia abajo repara síntomas. Si el bus de accesibilidad está muerto, el registro de Orca está lleno de errores, `pyatspi` está vacío y `spd-say` puede parecer irrelevante — "arreglar" Orca reinstalándolo no cambia nada. Observar de arriba hacia abajo es eficiente porque el reporte del usuario empieza ahí y el fallo de cada capa es visible; arreglar debe proceder **de abajo hacia arriba**, reparando la capa fallida más baja y volviendo a probar hacia arriba, porque esa reparación puede resolver todo lo de arriba de una sola vez.

**Q11.2** La capa 3, el **puente del toolkit** — `toolkit-accessibility` está en false, o las aplicaciones se iniciaron con `NO_AT_BRIDGE=1` / sin `QT_ACCESSIBILITY=1`. La capa 4 está sana: el bus respondió a `GetAddress` y el registro está corriendo. Que el bus sea alcanzable y esté vacío significa que ninguna aplicación eligió registrarse, que es una decisión del lado del cliente tomada en la inicialización del toolkit.

**Q11.3** `xkbset q` (o `gsettings list-recursively org.gnome.desktop.a11y.keyboard`). La causa casi segura es **Slow Keys** — activado deliberadamente o por mantener `Shift` accidentalmente durante ocho segundos con las secuencias de teclas AccessX activas — que hace que cada pulsación requiera una retención antes de registrarse y se lee exactamente como un teclado roto. Bounce Keys con un retardo grande produce el mismo reporte desde el otro lado. Limpiá con `xkbset -sl -bo` y después corregí las claves de la capa de escritorio para que el settings daemon no las vuelva a aplicar.

**Q11.4** (1) **La propia configuración de Orca**: la voz deshabilitada en `~/.local/share/orca/user-settings.conf` (`enableSpeech: false`), un perfil de verbosidad/puntuación que suprime la salida, o el `speechServerFactory` equivocado. (2) **El enrutado de audio a nivel de sesión**: Speech Dispatcher y Orca están vivos pero el flujo va a un sink silenciado, a otro dispositivo de salida, o a una instancia de PulseAudio/PipeWire que el proceso de Orca no puede alcanzar — que `spd-say` funcione desde tu shell interactivo no prueba que el proceso de Orca tenga el mismo entorno de audio, en particular cuando Orca fue iniciado por el arranque automático de la sesión con un entorno distinto.

</details>

---

### Mapeo del objetivo

| Área de conocimiento clave (106.3) | Cubierta en | Comandos / archivos principales |
|---|---|---|
| Ajustes visuales y temas (Alto contraste, Letra grande) | Bloque 5 | `gsettings org.gnome.desktop.interface`, `org.gnome.desktop.a11y.interface`, `setterm`, `setfont` |
| Magnificador de pantalla | Bloque 5 | `org.gnome.desktop.a11y.magnifier`, `xzoom`, `xmag`, `kmag` |
| Lector de pantalla | Bloques 2, 7, 10 | `orca`, `at-spi2-registryd`, Speakup, `emacspeak` |
| Línea braille | Bloque 8 | `brltty`, `/etc/brltty.conf`, BrlAPI, `xbrlapi` |
| Accesibilidad de teclado en el escritorio (AccessX, Sticky/Slow/Bounce/Toggle/Repeat/Mouse Keys) | Bloques 3, 4 | `xkbset`, `xset`, `org.gnome.desktop.a11y.keyboard` |
| Gestos / asistencia de puntero | Bloques 4, 9 | `org.gnome.desktop.a11y.mouse`, `xinput`, `org.gnome.desktop.peripherals.*` |
| Teclado en pantalla | Bloque 9 | `onboard`, `xvkbd`, OSK de GNOME Shell (GOK es histórico) |
| Síntesis de voz | Bloque 6 | `espeak-ng`, `festival`, `spd-say`, `/etc/speech-dispatcher/speechd.conf` |

### Fuentes

- LPI, *Exam 102-500 Objectives* (LPIC-1 versión 5.0) — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *Exam 101-500 Objectives* (LPIC-1 versión 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- freedesktop.org, *AT-SPI2 accessibility framework* — <https://www.freedesktop.org/wiki/Accessibility/AT-SPI2/>
- GNOME, *Orca Screen Reader documentation* — <https://help.gnome.org/users/orca/stable/>
- GNOME, *Universal Access / Accessibility settings* — <https://help.gnome.org/users/gnome-help/stable/a11y.html>
- Proyecto BRLTTY, *BRLTTY Manual and BrlAPI reference* — <https://brltty.app/documentation.html>
- Brailcom, *Speech Dispatcher documentation* — <https://freebsoft.org/speechd>
- Proyecto eSpeak NG — <https://github.com/espeak-ng/espeak-ng/blob/master/docs/guide.md>
- The Festival Speech Synthesis System — <https://www.cstr.ed.ac.uk/projects/festival/>
- Kernel de Linux, *Speakup User's Guide* — <https://www.kernel.org/doc/html/latest/admin-guide/spkguide.html>
- X.Org, *XKB — The X Keyboard Extension* — <https://www.x.org/releases/current/doc/kbproto/xkbproto.html>