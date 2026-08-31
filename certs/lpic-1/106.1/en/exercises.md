# LPIC-1 · Topic 106.1 — Install and Configure X11

## Guided Exercises

> **Lab requirements**
>
> * A Linux VM you can break: a graphical desktop (GNOME/KDE/Xfce) on Xorg *or* Wayland, plus root via `sudo`.
> * Console access (tty2–tty6 or the hypervisor console). Several steps stop the display manager; if your only access is the GUI you will lock yourself out.
> * Packages: `xorg-x11-server-Xorg`, `xorg-x11-apps` (or `xorg`, `x11-apps` on Debian/Ubuntu), `xorg-x11-server-Xephyr`/`xserver-xephyr`, `xorg-x11-server-Xvfb`/`xvfb`, `xorg-x11-utils`/`x11-utils`, `xauth`, `fontconfig`, `edid-decode`, `mesa-utils`/`glx-utils`.
> * Snapshot the VM before Exercise 4. You will be editing `/etc/X11/` and restarting the display server.
>
> Reference objective: <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

## Exercise 1 — Identify what is actually driving your display

Before touching a single configuration file, determine whether you are on X11, on Wayland, or on a Wayland compositor that is running X clients through Xwayland. Half of all "X11 configuration" bug reports are Wayland sessions where `xorg.conf` is never read.

### Steps

1. Ask the session itself what protocol it uses:

   ```console
   $ echo "$XDG_SESSION_TYPE"
   wayland
   ```

2. Ask `logind`, which is authoritative (the environment variable can be inherited or faked):

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

3. Look for the server processes themselves:

   ```console
   $ ps -eo pid,comm,args | grep -E '[X]org|[X]wayland|[g]nome-shell|[k]win|[s]way'
      1642 gnome-shell     /usr/bin/gnome-shell
      1789 Xwayland        /usr/bin/Xwayland :0 -rootless -noreset -accessx ...
   ```

4. Check both display sockets. X11 and Wayland use different namespaces:

   ```console
   $ echo "DISPLAY=$DISPLAY  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
   DISPLAY=:0  WAYLAND_DISPLAY=wayland-0
   $ ls -l /tmp/.X11-unix/ "$XDG_RUNTIME_DIR"/wayland-0
   srwxrwxrwx. 1 root root 0 Aug 26 09:11 /tmp/.X11-unix/X0
   srwxr-xr-x. 1 student student 0 Aug 26 09:11 /run/user/1000/wayland-0
   ```

5. List the X clients currently connected to the X server (or to Xwayland):

   ```console
   $ xlsclients
   student-vm  xterm
   ```

6. If your session reports `x11` instead, confirm the server is the real Xorg and note its version:

   ```console
   $ Xorg -version 2>&1 | head -3
   X.Org X Server 21.1.13
   X Protocol Version 11, Revision 0
   Build Operating System: linux
   ```

### Check your understanding

* **Q1.1** — Your session shows `Type=wayland` but `DISPLAY=:0` is set and `xterm` starts normally. Explain why, and name the component responsible.
* **Q1.2** — Why is `loginctl show-session ... -p Type` more trustworthy than `$XDG_SESSION_TYPE`?
* **Q1.3** — On a pure Wayland session, will edits to `/etc/X11/xorg.conf` change your monitor resolution? Justify the answer.
* **Q1.4** — `xlsclients` returns nothing on a busy GNOME/Wayland desktop full of open windows. Is that a fault?

---

## Exercise 2 — Verify that the video card and monitor are supported

The objective phrases this as "verify that the video card and monitor are supported by an X server". In a modern stack that verification happens at three layers: the **kernel DRM/KMS driver**, the **Xorg DDX driver module**, and the **EDID** that the monitor reports.

### Steps

1. Identify the graphics hardware and — critically — the kernel driver bound to it:

   ```console
   $ lspci -nnk | grep -EA3 'VGA|3D controller|Display controller'
   00:02.0 VGA compatible controller [0300]: Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] [8086:46a6] (rev 0c)
           Subsystem: Lenovo Device [17aa:22e5]
           Kernel driver in use: i915
           Kernel modules: i915, xe
   ```

2. Confirm the DRM subsystem created a card node and at least one connector:

   ```console
   $ ls /sys/class/drm/
   card1  card1-DP-1  card1-eDP-1  card1-HDMI-A-1  renderD128  version
   $ cat /sys/class/drm/card1-eDP-1/status /sys/class/drm/card1-eDP-1/enabled
   connected
   enabled
   ```

3. Check what the kernel said at boot:

   ```console
   $ journalctl -b -k --grep 'drm|i915|amdgpu|nouveau' | head -8
   kernel: i915 0000:00:02.0: [drm] Found ALDERLAKE_P (device ID 46a6) integrated display version 13.00
   kernel: i915 0000:00:02.0: [drm] Finished loading DMC firmware i915/adlp_dmc.bin (v2.20)
   kernel: [drm] Initialized i915 1.6.0 for 0000:00:02.0 on minor 1
   ```

4. List the Xorg driver modules (DDX) installed on the system:

   ```console
   $ ls /usr/lib64/xorg/modules/drivers/     # Debian/Ubuntu: /usr/lib/xorg/modules/drivers/
   amdgpu_drv.so  ati_drv.so  intel_drv.so  modesetting_drv.so  nouveau_drv.so  qxl_drv.so  vmware_drv.so
   ```

5. Read the monitor's EDID directly from the kernel and decode it:

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

6. From inside a running X session, cross-check what X believes about outputs and modes:

   ```console
   $ xrandr --query | head -6
   Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
   eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm
      1920x1080     60.05*+  48.00
   HDMI-1 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 597mm x 336mm
      1920x1080     60.00*+  50.00    59.94
      1680x1050     59.95
   ```

7. Confirm hardware acceleration actually landed (not `llvmpipe` software rendering):

   ```console
   $ glxinfo -B | grep -E 'OpenGL renderer|Device:'
       Device: Mesa Intel(R) Iris(R) Xe Graphics (ADL GT2) (0x46a6)
   OpenGL renderer string: Mesa Intel(R) Iris(R) Xe Graphics (ADL GT2)
   ```

### Check your understanding

* **Q2.1** — `lspci -nnk` shows `Kernel modules: nouveau` but no `Kernel driver in use:` line at all. What is the practical consequence for X, and what are two common causes?
* **Q2.2** — Which piece of information in step 5 tells you the *physical* size of the panel, and why does X care about it?
* **Q2.3** — `glxinfo -B` reports `llvmpipe (LLVM 17.0.6, 256 bits)`. Is X broken? What does this state actually mean?
* **Q2.4** — Your card is a recent AMD GPU and `/usr/lib64/xorg/modules/drivers/` contains no `amdgpu_drv.so`. Can X still drive the display? Name the module that would be used.
* **Q2.5** — A connector shows `status: connected` in sysfs but `disconnected` in `xrandr`. What is the most likely explanation on a laptop with a hybrid GPU?

---

## Exercise 3 — Read the Xorg log like a diagnostician

The Xorg log is the single most valuable artifact in this objective. Its prefix markers encode *where each setting came from*, which is exactly what you need when a configuration file is being ignored.

### Steps

1. Locate the log. Modern distributions run Xorg **rootless**, which changes the path:

   ```console
   $ ls -l ~/.local/share/xorg/Xorg.0.log /var/log/Xorg.0.log 2>&1
   ls: cannot access '/var/log/Xorg.0.log': No such file or directory
   -rw-r--r--. 1 student student 41220 Aug 26 09:11 /home/student/.local/share/xorg/Xorg.0.log
   ```

2. Identify which configuration sources the server used:

   ```console
   $ grep -E 'Using config|Using system config|Loading extension|Module Loader' ~/.local/share/xorg/Xorg.0.log
   [    24.601] (==) Using config file: "/etc/X11/xorg.conf"
   [    24.601] (==) Using config directory: "/etc/X11/xorg.conf.d"
   [    24.601] (==) Using system config directory "/usr/share/X11/xorg.conf.d"
   ```

3. Extract errors and warnings only:

   ```console
   $ grep -E '\((EE|WW)\)' ~/.local/share/xorg/Xorg.0.log
   [    24.655] (WW) Warning, couldn't open module nv
   [    24.655] (EE) Failed to load module "nv" (module does not exist, 0)
   [    24.802] (WW) modeset(0): Option "Rotate" is not used
   ```

4. Study the marker legend that the server prints in its own header:

   ```console
   $ sed -n '/Markers:/,/^\[.*(==) Log file/p' ~/.local/share/xorg/Xorg.0.log
   Markers: (--) probed, (**) from config file, (==) default setting,
            (++) from command line, (!!) notice, (II) informational,
            (WW) warning, (EE) error, (NI) not implemented, (??) unknown.
   ```

5. Find how the driver and screen were selected, and what EDID the server parsed:

   ```console
   $ grep -E 'modeset|EDID for output|Output .* connected|Modeline' ~/.local/share/xorg/Xorg.0.log | head -8
   [    24.711] (II) modeset(0): using drv /dev/dri/card1
   [    24.780] (II) modeset(0): EDID for output HDMI-1
   [    24.780] (II) modeset(0): Manufacturer: DEL  Model: a0b6  Serial#: 1112267076
   [    24.781] (II) modeset(0): Printing probed modes for output HDMI-1
   [    24.781] (II) modeset(0): Modeline "1920x1080"x60.0  148.50  1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync (67.5 kHz eP)
   [    24.783] (II) modeset(0): Output HDMI-1 connected
   ```

6. Confirm whether the server is listening on TCP (relevant for Exercises 6–8):

   ```console
   $ grep -iE 'nolisten|listen' ~/.local/share/xorg/Xorg.0.log
   [    24.602] (II) Module ABI versions:
   [    24.610] (--) Using syscons driver ...
   $ ss -ltnp 2>/dev/null | grep 600
   ```

   (An empty result is the expected, secure default.)

### Check your understanding

* **Q3.1** — A line reads `(**) Option "AccelMethod" "glamor"`. Which marker is that, and what does it prove about the origin of the setting?
* **Q3.2** — You edited `/etc/X11/xorg.conf.d/40-monitor.conf` and restarted X, but the log shows `(==) Using default setting` for the option you set. Give two independent explanations.
* **Q3.3** — Why did `/var/log/Xorg.0.log` disappear on modern distributions, and where does the log go instead?
* **Q3.4** — `(EE) Failed to load module "nv"` appears, yet the desktop starts fine. Is this a fatal error? What does that tell you about how Xorg selects drivers?
* **Q3.5** — Which single `grep` would you run first on a system that shows only a black screen after `startx`, and why that one?

---

## Exercise 4 — Generate and dissect an `xorg.conf`

> **Destructive step ahead.** Take a VM snapshot. Step 2 kills your graphical session.

### Steps

1. Record the current state so you can roll back:

   ```console
   $ systemctl get-default
   graphical.target
   $ ls -l /etc/X11/xorg.conf /etc/X11/xorg.conf.d/ 2>&1
   ls: cannot access '/etc/X11/xorg.conf': No such file or directory
   total 4
   -rw-r--r--. 1 root root 168 Aug 12 18:03 00-keyboard.conf
   ```

2. From a text console (Ctrl+Alt+F3), stop the display manager:

   ```console
   $ sudo systemctl isolate multi-user.target
   $ pgrep -a Xorg || echo "no X server running"
   no X server running
   ```

3. Have the server probe the hardware and write a configuration template:

   ```console
   $ sudo Xorg -configure
   ...
   Your xorg.conf file is /root/xorg.conf.new
   To test the server, run 'X -config /root/xorg.conf.new'
   ```

4. Inspect the generated skeleton — every LPIC-1 exam section is here:

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

5. Read the wiring between sections:

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

6. Test the file on a **spare display number**, without installing it:

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

7. Return the machine to normal:

   ```console
   $ sudo systemctl isolate graphical.target
   ```

### Check your understanding

* **Q4.1** — Which section is the root of the configuration tree, and which two section types does it reference?
* **Q4.2** — Give the reference chain from `ServerLayout` down to the physical monitor, naming each section.
* **Q4.3** — Why does `Xorg -configure` refuse to run while your desktop session is active, and why must it run as root?
* **Q4.4** — Where does `Xorg -configure` write its output, and why is that path *not* where X will look for it?
* **Q4.5** — What does `-retro` do, and why is it useful in exactly this test?
* **Q4.6** — On a current system, `Xorg -configure` fails with `Number of created screens does not match number of detected devices`. Does that mean the hardware is unsupported?

---

## Exercise 5 — Modular configuration with `/etc/X11/xorg.conf.d/`

Monolithic `xorg.conf` files are legacy. The supported approach is small snippets, each owning one concern, merged at server start.

### Steps

1. Look at what the vendor already ships (never edit these; they are package-owned):

   ```console
   $ ls /usr/share/X11/xorg.conf.d/
   10-quirks.conf  40-libinput.conf  70-wacom.conf
   ```

2. Create an admin-owned snippet that forces a keyboard layout:

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

3. Add a pointer snippet using `InputClass` matching instead of a static `InputDevice`:

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

4. Add a `Monitor` snippet that pins a preferred mode and position:

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

5. Validate syntax *before* restarting the session, on a spare display:

   ```console
   $ sudo systemctl isolate multi-user.target
   $ sudo X :1 -verbose 3 -logfile /tmp/Xtest.log ; echo "exit=$?"
   exit=1
   $ grep -E '\((EE|WW)\)' /tmp/Xtest.log
   [   12.004] (WW) The directory "/usr/share/fonts/X11/cyrillic" does not exist.
   ```

6. Confirm the merge order and which snippet won:

   ```console
   $ grep -E 'Using config directory|Parsing|InputClass' /tmp/Xtest.log | head
   [   11.960] (==) Using config directory: "/etc/X11/xorg.conf.d"
   [   11.960] (==) Using system config directory "/usr/share/X11/xorg.conf.d"
   [   12.110] (II) Using input driver 'libinput' for 'SynPS/2 Synaptics TouchPad'
   [   12.111] (**) Option "Tapping" "on"
   ```

7. Verify the live keyboard configuration once the desktop is back:

   ```console
   $ setxkbmap -query
   rules:      evdev
   model:      pc105
   layout:     es,us
   options:    grp:alt_shift_toggle,terminate:ctrl_alt_bksp
   ```

### Check your understanding

* **Q5.1** — Files in `/etc/X11/xorg.conf.d/` are read in what order, and why do the shipped names start with two digits?
* **Q5.2** — Two snippets, `10-touchpad.conf` and `90-touchpad.conf`, both set `Option "Tapping"` with different values on the same device. Which value applies?
* **Q5.3** — What is the functional difference between an `InputDevice` section and an `InputClass` section? Why did modern X move to the latter?
* **Q5.4** — If `/etc/X11/xorg.conf` exists *and* `/etc/X11/xorg.conf.d/` contains snippets, which is used?
* **Q5.5** — Why is editing files under `/usr/share/X11/xorg.conf.d/` a bad habit even when it works?
* **Q5.6** — In step 5, `X :1` exited with status 1 and only warnings in the log. What is the most likely benign reason, and how would a *real* syntax error look different?

---

## Exercise 6 — The `DISPLAY` variable, display numbers and nested servers

`Xephyr` and `Xvfb` let you practise the whole `DISPLAY`/`xauth` model safely, without touching the session you are sitting in — and they work on a headless server.

### Steps

1. Inspect the current value and decompose it:

   ```console
   $ echo "$DISPLAY"
   :0
   $ xdpyinfo | grep -E 'name of display|number of screens|dimensions'
   name of display:    :0
   number of screens:    1
     dimensions:    1920x1080 pixels (508x285 millimeters)
   ```

2. Start a **nested** X server inside your current desktop:

   ```console
   $ Xephyr :3 -screen 1280x800 -title "LPIC lab display :3" &
   [1] 8123
   $ ls -l /tmp/.X11-unix/
   srwxrwxrwx. 1 root    root    0 Aug 26 09:11 X0
   srwxrwxrwx. 1 student student 0 Aug 26 10:44 X3
   ```

3. Point a client at it two different ways — per-command and per-shell:

   ```console
   $ DISPLAY=:3 xterm -geometry 80x24 &
   $ export DISPLAY=:3
   $ xclock -update 1 &
   $ xlsclients -display :3
   student-vm  xterm
   student-vm  xclock
   ```

4. Prove that display number and screen number are different things:

   ```console
   $ DISPLAY=:3.0 xdpyinfo | grep 'name of display'
   name of display:    :3.0
   $ DISPLAY=:3.7 xdpyinfo
   X connection to :3.7 broken (explicit kill or server shutdown).
   ```

5. Start a **headless** virtual framebuffer — the standard tool for CI and remote testing:

   ```console
   $ Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp &
   $ DISPLAY=:99 xdpyinfo | grep -E 'dimensions|depth of root'
     dimensions:    1280x1024 pixels (325x270 millimeters)
     depth of root window:    24 planes
   $ DISPLAY=:99 xterm & sleep 2 ; DISPLAY=:99 xwd -root -out /tmp/shot.xwd
   ```

6. Observe the failure modes an unset or wrong `DISPLAY` produces:

   ```console
   $ unset DISPLAY ; xclock
   Error: Can't open display:
   $ DISPLAY=:42 xclock
   Error: Can't open display: :42
   $ DISPLAY=remote.example.com:0 xclock
   xclock: Error: Can't open display: remote.example.com:0
   ```

7. Clean up:

   ```console
   $ export DISPLAY=:0
   $ pkill Xephyr ; pkill Xvfb
   ```

### Check your understanding

* **Q6.1** — Decompose `DISPLAY=srv1.example.com:2.1` into its three components and state what each selects.
* **Q6.2** — What transport is used by `DISPLAY=:0` versus `DISPLAY=localhost:0`? Which file or socket does each touch?
* **Q6.3** — Which TCP port corresponds to display number `4`? Give the formula.
* **Q6.4** — Explain, in the X client/server model, which machine runs the *server* when you display a remote program on your laptop.
* **Q6.5** — Why is `Xvfb` the right tool for automated screenshot testing on a server with no GPU, and what does `1280x1024x24` mean?
* **Q6.6** — A cron job runs `xrandr` and fails with `Can't open display`. Name the two environment variables you must fix, and why setting only one is not enough.

---

## Exercise 7 — Access control: `xhost` and `xauth`

X has two independent authorization layers. `xhost` is host/user based and coarse; `xauth` is cookie based and is what actually protects a modern desktop.

### Steps

1. Inspect the host-based list:

   ```console
   $ xhost
   access control enabled, only authorized clients can connect
   SI:localuser:student
   SI:localuser:gdm
   ```

2. Inspect the cookie-based layer:

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

3. Demonstrate the failure a second user hits (create the user if needed):

   ```console
   $ sudo useradd -m tester
   $ sudo -u tester env DISPLAY=:0 xclock
   No protocol specified
   Error: Can't open display: :0
   ```

4. Grant access *correctly* — with a cookie, not by opening the server:

   ```console
   $ xauth extract - "$DISPLAY" | sudo -u tester env XAUTHORITY=/home/tester/.Xauthority xauth merge -
   $ sudo -u tester env DISPLAY=:0 XAUTHORITY=/home/tester/.Xauthority xclock &
   ```

5. Compare with the coarse alternative, and then undo it immediately:

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

6. Observe — **on the throwaway Xephyr display only** — what disabling access control looks like:

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

7. Inspect a cookie file the display manager owns, to see where cookies really live under GDM/SDDM:

   ```console
   $ sudo xauth -f /run/user/1000/gdm/Xauthority list 2>/dev/null || echo "path varies by display manager"
   student-vm/unix:0  MIT-MAGIC-COOKIE-1  c1d5e8a94b3f27061a8e5d2c9b4f7a13
   ```

### Check your understanding

* **Q7.1** — What exactly does `xhost +` do, and why is it treated as a full compromise of the session rather than a convenience? Name two concrete attacks it enables.
* **Q7.2** — Which authorization protocol does `xauth list` report, and where is the cookie stored by default?
* **Q7.3** — `xauth` is a client-side tool that edits a file. How does the X server ever learn about a cookie you merged?
* **Q7.4** — Distinguish `No protocol specified` from `Client is not authorized to connect to Server`. What does each imply?
* **Q7.5** — Root runs `xclock` on the user's `:0` and it fails. Why does being root not help, and what is the correct fix?
* **Q7.6** — `$XAUTHORITY` points to `/run/user/1000/.mutter-Xwaylandauth.XXXXXX` rather than `~/.Xauthority`. Explain, and state the consequence for a script that hardcodes `~/.Xauthority`.

---

## Exercise 8 — Remote display: SSH X11 forwarding vs. raw TCP

### Steps

1. Confirm the local server is **not** listening on TCP (the default since X.Org 1.17):

   ```console
   $ ss -ltn '( sport = :6000 )' ; pgrep -a Xorg | grep -o 'nolisten tcp' || echo "check Xorg args"
   State  Recv-Q Send-Q Local Address:Port Peer Address:Port
   ```

2. Enable forwarding on the **remote** host:

   ```console
   $ sudo grep -E '^\s*X11(Forwarding|DisplayOffset|UseLocalhost)' /etc/ssh/sshd_config
   X11Forwarding yes
   X11DisplayOffset 10
   X11UseLocalhost yes
   $ sudo systemctl reload sshd
   $ rpm -q xorg-x11-xauth || dpkg -l xauth   # xauth MUST exist on the remote host
   ```

3. Connect with **untrusted** forwarding and inspect what SSH set up for you:

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

4. Observe the untrusted-mode restrictions:

   ```console
   student@server1:~$ xdpyinfo | grep -c 'X-Resource\|SECURITY'
   1
   student@server1:~$ xwd -root -out /tmp/x.xwd
   X Error of failed request:  BadWindow (invalid Window parameter)
   ```

5. Retry with **trusted** forwarding and compare:

   ```console
   $ ssh -Y student@server1 'DISPLAY=localhost:10.0 xwd -root -out /tmp/x.xwd && echo captured'
   captured
   ```

6. Watch a forwarded session time out (untrusted cookies expire; default `ForwardX11Timeout` is 20 minutes):

   ```console
   $ ssh -o ForwardX11Timeout=30 -X student@server1
   student@server1:~$ sleep 45 ; xclock
   X11 connection rejected because of wrong authentication.
   Error: Can't open display: localhost:10.0
   ```

7. For contrast only — do **not** leave this enabled — see what raw TCP would require:

   ```console
   # Would need: Xorg started with '-listen tcp', firewall open on 6000/tcp,
   # and either xhost + (insecure) or a cookie copied to the remote host.
   $ grep -rn 'nolisten' /usr/lib/systemd/system/display-manager.service /etc/gdm/custom.conf 2>/dev/null
   ```

### Check your understanding

* **Q8.1** — Why is `DISPLAY=localhost:10.0` rather than `laptop:0` inside an SSH session? What is `X11DisplayOffset` for?
* **Q8.2** — State the difference between `ssh -X` and `ssh -Y` in terms of the X SECURITY extension, and when each is appropriate.
* **Q8.3** — X11 forwarding fails with `X11 forwarding request failed on channel 0`, and `$DISPLAY` is empty on the remote host. Give three checks, in order.
* **Q8.4** — With `X11UseLocalhost yes`, port 6010 binds to `127.0.0.1`. What breaks if you need a *container* on the remote host to use that display, and what is the setting?
* **Q8.5** — Why is SSH forwarding preferred over `xhost +` plus `-listen tcp`, even inside a trusted LAN? Mention confidentiality and authentication separately.
* **Q8.6** — A long-running GUI over `ssh -X` dies after ~20 minutes with an authentication error. Name the cause and two fixes.

---

## Exercise 9 — Fonts: the X font server and its modern replacement

The objective asks for *awareness of the X font server*. In practice you must know both models: the legacy **core X font** path (server-side, `xfs`, `FontPath`) and **fontconfig** (client-side, `fc-*`), which is what every modern toolkit actually uses.

### Steps

1. Query the server's core font path:

   ```console
   $ xset q | sed -n '/Font Path/,+2p'
   Font Path:
     catalogue:/etc/X11/fontpath.d,built-ins
   ```

2. List the core fonts the server can serve, and try a legacy XLFD:

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

3. Build a core-font directory by hand — this is the mechanism `FontPath` consumes:

   ```console
   $ mkdir -p ~/lab-fonts && cp /usr/share/fonts/liberation-mono/*.ttf ~/lab-fonts/ 2>/dev/null
   $ cd ~/lab-fonts && mkfontscale . && mkfontdir .
   $ head -3 fonts.dir
   4
   LiberationMono-Regular.ttf -1-liberation mono-medium-r-normal--0-0-0-0-m-0-iso10646-1
   ```

4. Add it to the running server's font path, then remove it:

   ```console
   $ xset +fp ~/lab-fonts
   $ xset fp rehash
   $ xset q | sed -n '/Font Path/,+2p'
   Font Path:
     /home/student/lab-fonts,catalogue:/etc/X11/fontpath.d,built-ins
   $ xset -fp ~/lab-fonts
   ```

5. Inspect the legacy font server configuration if `xfs` is present (many distributions no longer ship it):

   ```console
   $ systemctl status xfs 2>&1 | head -3
   Unit xfs.service could not be found.
   $ ls /etc/X11/fs/config 2>&1
   ls: cannot access '/etc/X11/fs/config': No such file or directory
   ```

   A historic `xfs` deployment looked like this: the daemon listened on **TCP 7100**, `/etc/X11/fs/config` defined `catalogue = ...` and `port = 7100`, and clients were pointed at it with `FontPath "tcp/fontsrv.example.com:7100"` or `FontPath "unix/:7100"` in the `Files` section of `xorg.conf`.

6. Now work with the mechanism that is actually in use today:

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

7. Install a font for one user and refresh the cache:

   ```console
   $ mkdir -p ~/.local/share/fonts && cp ~/lab-fonts/*.ttf ~/.local/share/fonts/
   $ fc-cache -fv ~/.local/share/fonts | tail -2
   /home/student/.local/share/fonts: caching, new cache contents: 4 fonts, 0 dirs
   fc-cache: succeeded
   $ fc-list | grep -c "$HOME/.local/share/fonts"
   4
   ```

### Check your understanding

* **Q9.1** — Explain the architectural difference between core X fonts and fontconfig: which process opens the font file in each model?
* **Q9.2** — What was `xfs` for, on which port did it listen, and what made it obsolete?
* **Q9.3** — In which `xorg.conf` section does `FontPath` belong, and give one valid value pointing at a font server.
* **Q9.4** — `xlsfonts` shows 17 fonts while `fc-list` shows 612. Explain the discrepancy without concluding anything is broken.
* **Q9.5** — What do `mkfontscale` and `mkfontdir` produce, and why does `xset fp rehash` exist?
* **Q9.6** — A user drops a `.ttf` in `~/.local/share/fonts` and the font does not appear in their editor. What is the missing command, and why is a logout usually unnecessary?

---

## Exercise 10 — Troubleshoot a broken X start (`~/.xsession-errors` and the journal)

### Steps

1. Break the configuration deliberately, with a driver that does not exist:

   ```console
   $ sudo tee /etc/X11/xorg.conf.d/99-broken.conf >/dev/null <<'EOF'
   Section "Device"
       Identifier "Card0"
       Driver     "sisusb"
       Option     "NoAccel" "true"
   EndSection
   EOF
   ```

2. Attempt a start on a spare display from a text console and capture the failure:

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

3. Read the log's own summary block, which names the file to send to a bug report:

   ```console
   $ tail -6 /tmp/Xbroken.log
   (EE)
   Please consult the The X.Org Foundation support at http://wiki.x.org
   for help.
   (EE) Please also check the log file at "/tmp/Xbroken.log" for additional information.
   (EE)
   (EE) Server terminated with error (1). Closing log file.
   ```

4. Inspect the session-level error file, which captures *client* failures rather than server ones:

   ```console
   $ ls -l ~/.xsession-errors 2>/dev/null && tail -5 ~/.xsession-errors
   -rw-------. 1 student student 3120 Aug 26 09:12 /home/student/.xsession-errors
   openConnection: connect: No such file or directory
   cannot connect to brltty at :0
   gnome-session-binary[1602]: WARNING: Failed to start app: xdg-desktop-portal
   ```

5. On systemd-based desktops, read the equivalent from the journal:

   ```console
   $ journalctl --user -b -u gnome-session-manager --no-pager | tail -5
   $ journalctl -b _COMM=gdm-x-session --no-pager | tail -5
   gdm-x-session[1521]: (EE) Fatal server error:
   gdm-x-session[1521]: (EE) no screens found(EE)
   ```

6. Repair and confirm:

   ```console
   $ sudo rm /etc/X11/xorg.conf.d/99-broken.conf
   $ X :1 -logfile /tmp/Xok.log & sleep 2 ; DISPLAY=:1 xdpyinfo | head -2 ; pkill -f 'X :1'
   name of display:    :1
   version number:    11.0
   $ sudo systemctl isolate graphical.target
   ```

7. Practise the emergency recovery path you would use over SSH on a headless-by-accident machine:

   ```console
   $ sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.disabled   # let X autodetect
   $ sudo systemctl set-default multi-user.target             # boot to text next time
   $ sudo systemctl isolate graphical.target                  # test without rebooting
   ```

### Check your understanding

* **Q10.1** — What is the difference in scope between `/var/log/Xorg.0.log` (or `~/.local/share/xorg/Xorg.0.log`) and `~/.xsession-errors`?
* **Q10.2** — `no screens found` is the symptom. Name three distinct root causes that all produce it.
* **Q10.3** — Your only access is SSH and the machine boots to a black graphical screen. Give the two-command recovery that guarantees a usable text login on the next boot.
* **Q10.4** — Why is `X :1 -logfile /tmp/x.log` safer for testing than restarting the display manager?
* **Q10.5** — `~/.xsession-errors` is missing entirely on a GNOME/Wayland system. Where do client errors go instead, and with which command do you read them?
* **Q10.6** — The file `~/.xsession-errors` has grown to 4 GB. What does that usually indicate, and why can it fill `/home`?

---

## Exercise 11 — Wayland awareness and Xwayland

### Steps

1. Log into a Wayland session and enumerate the compositor's view:

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

2. Confirm Xwayland is present and see who owns the X socket:

   ```console
   $ pgrep -a Xwayland
   1789 /usr/bin/Xwayland :0 -rootless -noreset -accessx -core -auth /run/user/1000/.mutter-Xwaylandauth.QK2R41 -listenfd 4
   $ xdpyinfo | grep -E 'vendor string|name of display'
   name of display:    :0
   vendor string:    The X.Org Foundation
   ```

3. Run a legacy X client and confirm it goes through Xwayland:

   ```console
   $ xeyes &
   $ xlsclients
   student-vm  xeyes
   ```

4. Observe what X tooling can and cannot do under Wayland:

   ```console
   $ xrandr --output eDP-1 --mode 1280x720
   xrandr: Configure crtc 0 failed
   $ xdotool search --name "Firefox"
   $ xhost +SI:localuser:tester      # affects only Xwayland clients
   localuser:tester being added to access control list
   ```

5. Compare per-application scaling ownership:

   ```console
   $ gnome-randr 2>/dev/null || echo "use the compositor's own tool / Settings → Displays"
   $ echo "GDK_BACKEND=$GDK_BACKEND QT_QPA_PLATFORM=$QT_QPA_PLATFORM"
   GDK_BACKEND= QT_QPA_PLATFORM=
   $ GDK_BACKEND=x11 gedit &   # forces a GTK app through Xwayland
   ```

6. Switch a session back to X11 to compare behaviour (GDM):

   ```console
   $ sudo grep -n 'WaylandEnable' /etc/gdm/custom.conf
   #WaylandEnable=false
   $ sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm/custom.conf
   $ sudo systemctl restart gdm      # logs you out
   $ echo "$XDG_SESSION_TYPE"
   x11
   ```

### Check your understanding

* **Q11.1** — In one sentence each, state the architectural difference between X11 and Wayland regarding the display server, the window manager and the compositor.
* **Q11.2** — What is Xwayland, and why does `DISPLAY` remain set in a Wayland session?
* **Q11.3** — `xrandr --output ... --mode ...` fails under Wayland. Why, and what replaces it?
* **Q11.4** — Why does `xdotool search` find nothing for native Wayland windows, and why is that a deliberate security property rather than a bug?
* **Q11.5** — A screen-recording tool "worked on X11" and shows a black frame on Wayland. Name the mechanism it must use instead.
* **Q11.6** — Under Wayland, does `xhost +` still create a risk? Scope your answer precisely.

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Exercise 1

**A1.1** — The compositor spawned **Xwayland**, a rootless X server that translates the X11 protocol into Wayland surfaces. It owns display `:0` and the socket `/tmp/.X11-unix/X0`, so `DISPLAY=:0` is valid and legacy X clients keep working. The session type is still `wayland`; there is no Xorg process.

**A1.2** — `$XDG_SESSION_TYPE` is an ordinary environment variable: it is inherited by child processes, survives `su`, can be stale inside `tmux`/`screen`/cron, and can simply be exported by hand. `loginctl` reads the session record `systemd-logind` created at login, which reflects what the display manager actually started.

**A1.3** — No. `xorg.conf` and `xorg.conf.d/` are parsed **only by the Xorg server**. A Wayland compositor (mutter, KWin, sway) has its own configuration and never reads them. Xwayland itself accepts command-line flags from the compositor, not an `xorg.conf`. Mode setting under Wayland is done by the compositor via DRM/KMS.

**A1.4** — No. `xlsclients` enumerates clients connected to the **X server**. On Wayland, native clients (GNOME apps, Firefox in Wayland mode) connect to the compositor, not to Xwayland, so they are invisible to it. Empty output means "no X11 clients right now", not "no windows".

---

### Exercise 2

**A2.1** — No kernel driver is bound, so there is no `/dev/dri/cardN` KMS device. The `modesetting` DDX has nothing to drive and X falls back to `fbdev`/`vesa` or fails with `no screens found`. Common causes: (a) the module is blacklisted — typically `nouveau` blacklisted by an NVIDIA proprietary install, check `/etc/modprobe.d/` and the kernel command line for `nomodeset`/`modprobe.blacklist=`; (b) the module is missing from the installed kernel/initramfs, or firmware failed to load (`journalctl -b -k | grep -i firmware`).

**A2.2** — `Maximum image size: 60 cm x 34 cm` and the per-mode `597 mm x 336 mm`. X uses physical dimensions together with the resolution to compute **DPI**, which drives font and UI scaling. A monitor reporting a wrong or absent physical size is the classic cause of comically large or tiny fonts; you can override it with `xrandr --dpi` or a `DisplaySize` entry in a `Monitor` section.

**A2.3** — X is working, but **without hardware acceleration**: `llvmpipe` is Mesa's CPU rasteriser. Everything renders correctly and slowly, video and compositing stutter. It signals a missing/incorrect DRM driver, a missing Mesa driver package, a GPU whitelist issue, or a VM without 3D acceleration enabled.

**A2.4** — Yes. The generic **`modesetting_drv.so`** DDX drives any GPU that has a kernel KMS driver, using glamor over OpenGL for acceleration. The dedicated `amdgpu`/`intel` DDX drivers are optional optimisations; several distributions deliberately ship only `modesetting`.

**A2.5** — The connector belongs to a different GPU than the one X is driving — typically the discrete GPU in a hybrid (Optimus/PRIME) laptop, where the external port is wired to the dGPU while X runs on the integrated one. `xrandr --listproviders` and PRIME output offloading (`xrandr --setprovideroutputsource`) are the tools; sysfs sees all cards, X sees only the screens it configured.

---

### Exercise 3

**A3.1** — `(**)` means **"from config file"**. It proves the value came from `xorg.conf` or a snippet in a config directory, not from probing (`--`), not from a compiled-in default (`==`), and not from the command line (`++`). This single distinction resolves most "my configuration is being ignored" reports.

**A3.2** — (1) The snippet is not being read: wrong directory, wrong extension (must be `.conf`), unreadable permissions, or overridden by a later-sorting file. Verify with the `(==) Using config directory` lines and by grepping for the option name. (2) The section does not match: an `InputClass` whose `Match*` directives never match the device, or a `Monitor` `Identifier` that does not correspond to the actual output name (`HDMI-1` vs `HDMI-A-1`). A third possibility: the session is Wayland, so nothing is read at all.

**A3.3** — Xorg is no longer installed setuid-root on most distributions; it runs as the logged-in user via `systemd-logind` (rootless X). An unprivileged process cannot write to `/var/log`, so the log goes to **`~/.local/share/xorg/Xorg.<display>.log`**. When X *is* started as root (`startx` as root, or a setuid build) the old path is still used.

**A3.4** — Not fatal. `(EE)` marks an error condition, not necessarily a fatal one; only `Fatal server error` ends the server. Xorg tries a list of candidate drivers — from `xorg.conf`, then autodetection, then generic fallbacks — and a failed candidate is logged and skipped. A stale `Driver "nv"` line in an old `xorg.conf` produces exactly this.

**A3.5** — `grep -E '\(EE\)' <logfile>`. Errors are the only class that can abort the server, and the fatal-error block at the end of the log names both the cause (`no screens found`, `Cannot run in framebuffer mode`, `parse error`) and the log path. Warnings are almost always noise (missing font directories, unused options).

---

### Exercise 4

**A4.1** — **`ServerLayout`** is the root. It references **`Screen`** sections (with their position on the virtual desktop) and **`InputDevice`** sections (`CorePointer`, `CoreKeyboard`). If several `ServerLayout` sections exist, the first is used unless `-layout` selects another.

**A4.2** — `ServerLayout` → `Screen` → (`Device` **and** `Monitor`). The `Screen` binds one graphics `Device` (the driver/card) to one `Monitor` (the output's sync ranges, modes and physical size) and defines depth/resolution in its `Display` subsections.

**A4.3** — `Xorg -configure` starts a temporary server to probe the hardware; it cannot do that while another server already holds the VT and the DRM master lease. Root is required because probing opens PCI resources and `/dev/dri/*` device nodes directly, and because it writes to `/root`.

**A4.4** — It writes **`/root/xorg.conf.new`** (in the caller's home; historically the current directory). X never reads that path. The file is a template to be reviewed, tested with `X -config`, and only then installed as `/etc/X11/xorg.conf` — deliberately, so a bad probe cannot break the next boot.

**A4.5** — `-retro` draws the classic black-and-white weave root pattern with an X cursor instead of a plain black root window. On a test display it distinguishes "the server started and is running with no clients" from "the server died / the screen is genuinely blank".

**A4.6** — No. It is a known limitation of `-configure` with KMS drivers: the probe enumerates devices differently from how the server creates screens. The correct modern conclusion is that a static `xorg.conf` is unnecessary — autodetection through `modesetting` works — and any needed tweak belongs in a small `xorg.conf.d` snippet.

---

### Exercise 5

**A5.1** — In **lexicographic (ASCII) order** within each directory. The vendor directory `/usr/share/X11/xorg.conf.d` is read before the administrator directory `/etc/X11/xorg.conf.d`; the log records both with `(==) Using config directory` / `Using system config directory`. The numeric prefixes make that order explicit and controllable — `10-` loads before `50-` before `90-`.

**A5.2** — The value from **`90-touchpad.conf`**. For `InputClass`, later matching sections are applied on top of earlier ones, so the last matching assignment of a given option wins.

**A5.3** — `InputDevice` statically declares one device and must be referenced from `ServerLayout`; it hardcodes a device path. `InputClass` declares *rules* that match devices dynamically at hotplug time via `MatchIsPointer`, `MatchIsKeyboard`, `MatchIsTouchpad`, `MatchDriver`, `MatchProduct`, `MatchDevicePath`. With `udev` hotplugging, devices appear and disappear at runtime, so a static declaration cannot describe a USB mouse plugged in after the server started.

**A5.4** — **Both.** They are merged, not exclusive: the config directories are read and then `xorg.conf` is applied, and per `xorg.conf(5)` the options in `xorg.conf` take precedence over the directory files. This is the trap behind "my snippet is ignored" — a leftover monolithic `xorg.conf` is quietly overriding it.

**A5.5** — Those files are owned by a package. The next update of `xorg-x11-drv-libinput` (or equivalent) overwrites your edit or leaves a `.rpmnew`/`.dpkg-dist` alongside it, so the change silently disappears or silently stops applying. `/etc/X11/xorg.conf.d/` is the administrator's namespace, is read later, and survives updates.

**A5.6** — On a headless/console test, `X :1` frequently exits because it cannot take the VT, has no input devices to open, or exits when its (nonexistent) client disconnects — a **runtime** failure after successful parsing. A real syntax error appears *before* any device probing, as `(EE) Parse error on line N of section ... in file /etc/X11/xorg.conf.d/40-monitor.conf` followed by `Fatal server error: no screens found`.

---

### Exercise 6

**A6.1** — `srv1.example.com` = **hostname**, the machine running the X *server* (the display); `2` = **display number**, which X server instance on that host (TCP port 6000+2, or socket `/tmp/.X11-unix/X2`); `1` = **screen number**, which screen within that display, meaningful only on multi-screen (Zaphod) layouts. Omitting the screen defaults to `0`.

**A6.2** — `:0` (empty hostname) uses the **local Unix domain socket** `/tmp/.X11-unix/X0`, which is faster and supports peer-credential checks (`SI:localuser:`). `localhost:0` uses **TCP over the loopback interface**, port 6000 — which requires the server to be started with `-listen tcp`, and therefore usually fails on a default install.

**A6.3** — `6000 + display_number` → **6004**. Display `:10` (SSH's first forwarded display) is port 6010.

**A6.4** — The **laptop** runs the X server, because the server owns the display hardware, keyboard and mouse. The remote machine runs the *client* (the application). This inversion relative to normal client/server intuition is a classic exam point: the server is where you sit.

**A6.5** — `Xvfb` implements a complete X server in memory with no hardware output, so GUI applications, toolkits and screenshot tools run unchanged on a machine with no GPU or monitor. `1280x1024x24` = width × height × colour **depth in bits per pixel** (24-bit truecolour) for screen 0.

**A6.6** — `DISPLAY` **and** `XAUTHORITY`. `DISPLAY` tells the client which server to contact; without `XAUTHORITY` (or a readable `~/.Xauthority`) the client has no MIT-MAGIC-COOKIE-1 credential and is rejected with `No protocol specified`. Cron starts with a minimal environment and no session, so both must be set explicitly.

---

### Exercise 7

**A7.1** — It **disables host-based access control entirely**: any client from any host that can reach the server may connect, with no cookie. X has no per-client isolation, so a connected client can (a) read every keystroke going to any window via `XQueryKeymap`/the XTEST and RECORD extensions — a full keylogger, capturing passwords typed into any application; (b) capture the screen contents (`xwd -root`) and inject synthetic input events into other applications, e.g. typing into a root terminal. It is equivalent to handing over the session.

**A7.2** — **`MIT-MAGIC-COOKIE-1`**: a 128-bit shared secret sent by the client at connection setup. It is stored in the file named by `$XAUTHORITY`, defaulting to **`~/.Xauthority`**; display managers frequently override that with a per-session file under `/run/user/<uid>/`.

**A7.3** — It does not learn it from the file. The server holds its authorization list in memory, seeded at startup from the `-auth <file>` argument the display manager passed it. `xauth` edits the **client-side** file so clients present a cookie the server already accepts. Adding a brand-new cookie to your file does not grant access; you must copy an *existing* valid cookie (which is exactly what `xauth extract | xauth merge` does).

**A7.4** — `No protocol specified` means the client had **no credential to offer** — `XAUTHORITY` unset/unreadable, or the file has no entry for that display. `Client is not authorized to connect to Server` means a credential **was offered and rejected** — a stale cookie from a previous session, or the wrong display entry. The first is a lookup problem, the second a mismatch problem.

**A7.5** — X authorization is by cookie, not by UID; root has no special standing in the X protocol. Root's `~/.Xauthority` (`/root/.Xauthority`) contains no cookie for the user's display. The correct fix is `sudo XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:0 <command>`, or merging the cookie — not `xhost +`.

**A7.6** — Under GNOME/Wayland, mutter starts Xwayland with `-auth` pointing to a **per-session temporary file** it created in `$XDG_RUNTIME_DIR`, so `~/.Xauthority` may not exist or may be stale. A script that hardcodes `~/.Xauthority` (common in cron jobs, monitoring agents and `sudo` wrappers) will fail with `No protocol specified`. Read `$XAUTHORITY` from the target user's session environment instead — e.g. from `/proc/<pid>/environ` of a session process.

---

### Exercise 8

**A8.1** — SSH does not forward to your real display; it creates a **proxy X server endpoint on the remote host** and tunnels the protocol back over the encrypted SSH channel. That endpoint lives on the remote machine's loopback, hence `localhost`. `X11DisplayOffset` (default **10**) is the lowest display number SSH may allocate, keeping forwarded displays clear of real local servers on `:0`–`:9`.

**A8.2** — `-X` requests **untrusted** forwarding: the client is subject to the X **SECURITY** extension, which blocks screen capture, input injection into other clients, and access to other clients' resources, and whose token expires after `ForwardX11Timeout`. `-Y` requests **trusted** forwarding: the remote client has the same power over your display as a local one. Use `-X` for untrusted or shared hosts; use `-Y` only for hosts you administer, or when an application genuinely breaks under the restrictions.

**A8.3** — (1) On the **remote** host: `X11Forwarding yes` in `/etc/ssh/sshd_config` and `sshd` reloaded. (2) On the **remote** host: the `xauth` binary must be installed — without it sshd cannot create the proxy cookie and forwarding fails even when enabled. (3) On the **local** side: `ForwardX11 yes`/`-X`, plus a working local `$DISPLAY` and a valid local cookie. Run `ssh -vv -X host` and read the `debug1: Requesting X11 forwarding` exchange.

**A8.4** — Binding to `127.0.0.1` means only processes in the remote host's own network namespace can reach port 6010; a container with its own namespace cannot. `X11UseLocalhost no` makes sshd bind the wildcard address so other hosts/namespaces can connect — at the cost of exposing the forwarded display to the network, which is why `yes` is the default. Prefer bind-mounting the socket or using `--network=host` over changing this.

**A8.5** — **Confidentiality**: raw X11 over TCP is cleartext — every keystroke, window title and pixel crosses the LAN unencrypted and is trivially sniffable; SSH encrypts the whole channel. **Authentication**: `xhost +` authorizes by *nothing at all* (and even `xhost +host` authorizes every user on that host, not a person), whereas SSH forwarding issues a per-session cookie tied to an authenticated login, and untrusted mode additionally constrains what that client may do.

**A8.6** — `ssh -X` generates an untrusted cookie with a lifetime of `ForwardX11Timeout` (default **20 minutes**); when it expires, new connections to the display are rejected. Fixes: use `-Y` (trusted, no expiry) for a host you trust, or raise the limit with `-o ForwardX11Timeout=<seconds>` / a `ForwardX11Timeout` line in `~/.ssh/config`. Note that already-open windows usually survive; it is *new* connections that fail.

---

### Exercise 9

**A9.1** — With **core X fonts**, the *X server* opens the font files, rasterises the glyphs and ships them to the client; the client only names a font with an XLFD and asks the server to draw text. With **fontconfig/Xft**, the *client* opens the font file, rasterises it locally (FreeType), applies antialiasing/hinting/subpixel rendering, and sends the resulting glyph images to the server through the RENDER extension. That is why client-side fonts look identical locally and remotely, and why the server's font path is irrelevant to modern applications.

**A9.2** — `xfs` (X Font Server) centralised core fonts so many X servers — notably diskless X terminals — could share one font repository over the network instead of each installing fonts locally. It listened on **TCP port 7100**. It became obsolete because client-side rendering (Xft/fontconfig/RENDER) moved font handling out of the server entirely, and because modern scaled/antialiased/hinted rendering was impossible in the core font model. Most distributions no longer ship it.

**A9.3** — The **`Files`** section. Example: `FontPath "tcp/fontsrv.example.com:7100"` (or `FontPath "unix/:7100"` for a local `xfs`, and `FontPath "/usr/share/fonts/X11/misc/"` for a plain directory).

**A9.4** — They count different things. `xlsfonts` lists **core fonts known to the X server** through its font path — a modern install ships only a handful of built-ins plus `fixed`/`cursor`. `fc-list` lists **fontconfig fonts available to clients** from `/usr/share/fonts`, `~/.local/share/fonts`, etc. Applications use the second set almost exclusively, so 17 core fonts is normal and healthy.

**A9.5** — `mkfontscale` generates **`fonts.scale`** (an index of scalable fonts — TTF/OTF/Type1 — with their XLFD names) and `mkfontdir` generates **`fonts.dir`** (the combined index the server actually reads). `xset fp rehash` tells a *running* server to re-read the directories in its font path, so newly added core fonts are picked up without restarting X.

**A9.6** — `fc-cache -f` (optionally `-v`, optionally with the directory). Fontconfig caches directory scans; until the cache is refreshed, `fc-list`/`fc-match` do not see the new file. A logout is unnecessary because each client consults fontconfig at font-lookup time — although already-running applications typically need to be restarted to re-query the font list.

---

### Exercise 10

**A10.1** — The **Xorg log** is written by the X *server*: hardware probing, driver and module loading, configuration sources, EDID and modes, extension initialisation, fatal server errors. **`~/.xsession-errors`** collects stdout/stderr of the *session's clients* — the `Xsession` scripts, window manager, panel, autostart applications. Server won't start → Xorg log. Server starts but the desktop is broken/empty → `.xsession-errors`.

**A10.2** — (1) No usable driver: the configured `Driver` does not exist, or no DDX matched the hardware (`No drivers available`). (2) No KMS device: kernel driver not loaded, `nomodeset` on the kernel command line, GPU passed through/claimed by another driver, or `/dev/dri/card0` permissions. (3) Configuration mismatch: a `Device` section pinned to the wrong `BusID`, or `Monitor` sync ranges that exclude every probed mode so no valid mode remains.

**A10.3** — `sudo mv /etc/X11/xorg.conf /etc/X11/xorg.conf.disabled` (remove the offending config so X autodetects) and `sudo systemctl set-default multi-user.target` (boot to a text login regardless). The second command alone guarantees a login prompt; the first removes the likely cause. Restore with `systemctl set-default graphical.target` once fixed.

**A10.4** — It touches nothing the running system depends on: it uses a spare display number, writes its log to a path you choose, does not stop the display manager, does not log out the user, and dies harmlessly if the configuration is wrong. Restarting the display manager terminates every graphical process — unsaved work included — and if the new configuration is broken, you lose the environment you were debugging from.

**A10.5** — `~/.xsession-errors` is produced by the traditional `Xsession` shell scripts, which systemd-based sessions no longer use. Client output goes to the **systemd journal**: `journalctl --user -b` for the whole user session, `journalctl --user -b -u <unit>` for one service, or `journalctl -b _COMM=gnome-shell` / `_COMM=gdm-x-session` for a specific binary.

**A10.6** — A client stuck in an error loop is writing to stderr thousands of times per second — a crashing panel applet, a misconfigured input method, or a GTK/Qt warning storm. The file is unrotated and lives in the user's home, so it can exhaust the `/home` filesystem or the user's quota, which then breaks *login itself* (the session cannot write its dotfiles). Diagnose with `sort ~/.xsession-errors | uniq -c | sort -rn | head` to find the repeating message.

---

### Exercise 11

**A11.1** — **X11**: a single display server (Xorg) owns the hardware; the window manager is a separate, ordinary X client that positions windows; a compositor is yet another optional client. **Wayland**: the compositor *is* the display server *and* the window manager — one process owns KMS/DRM output, input via libinput, and composition. Consequence: clients cannot inspect or manipulate each other, because there is no shared server to ask.

**A11.2** — Xwayland is an X server implementation that renders X clients into Wayland surfaces, letting unported X11 applications run in a Wayland session. It claims an X display number (usually `:0`) and the compositor exports `DISPLAY` so those clients find it. This is why `DISPLAY` being set proves nothing about the session type.

**A11.3** — Mode setting belongs to the **compositor**, which is the DRM master; Xwayland is rootless and has no CRTCs of its own, so RandR mode-setting requests fail. Configuration is done through the compositor's own interface — GNOME Settings/`gnome-monitor-config`, KDE `kscreen-doctor`, `sway output ...`, or `wlr-randr` on wlroots compositors.

**A11.4** — Native Wayland clients never connect to Xwayland, and the Wayland protocol gives no client the ability to enumerate, read or inject into another client's windows. `xdotool` speaks X11 and can therefore only see Xwayland clients. This is deliberate: it removes exactly the keylogging and input-injection capabilities described in A7.1, which were unfixable in X11's design.

**A11.5** — The **`xdg-desktop-portal`** screen-cast interface (`org.freedesktop.portal.ScreenCast`), backed by **PipeWire**, with the compositor prompting the user to consent and choose what to share. Direct framebuffer grabs (`xwd -root`, X11 screen capture APIs) see only the Xwayland layer, which is why the recording is black.

**A11.6** — Yes, but with a **bounded** scope: it disables access control on the **Xwayland** server only. Any local process could then connect to Xwayland and spy on or inject into X11 clients running there — which, on a typical desktop, still includes browsers or Electron apps in X11 mode, terminal emulators and legacy tools. Native Wayland clients are unaffected. It is still wrong to do, just no longer a whole-session compromise.

</details>

---

## Sources

* LPI — Exam 101 Objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
* X.Org — `xorg.conf(5)` configuration file manual: <https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml>
* X.Org — `Xorg(1)` server manual: <https://www.x.org/releases/current/doc/man/man1/Xorg.1.xhtml>
* X.Org — `X(7)`, display names and access control: <https://www.x.org/releases/current/doc/man/man7/X.7.xhtml>
* X.Org — `xauth(1)`: <https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml>
* X.Org — `xhost(1)`: <https://www.x.org/releases/current/doc/man/man1/xhost.1.xhtml>
* X.Org — `Xephyr(1)` and `Xvfb(1)`: <https://www.x.org/releases/current/doc/man/man1/Xephyr.1.xhtml>, <https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml>
* X.Org wiki — fonts and the deprecation of the core font system: <https://www.x.org/wiki/Development/Documentation/Fonts/>
* freedesktop.org — fontconfig user documentation: <https://www.freedesktop.org/software/fontconfig/fontconfig-user.html>
* freedesktop.org — Wayland architecture: <https://wayland.freedesktop.org/architecture.html>
* freedesktop.org — Xwayland: <https://wayland.freedesktop.org/xserver.html>
* freedesktop.org — xdg-desktop-portal (ScreenCast): <https://flatpak.github.io/xdg-desktop-portal/docs/>
* OpenSSH — `ssh(1)` and `sshd_config(5)` (X11 forwarding options): <https://man.openbsd.org/ssh>, <https://man.openbsd.org/sshd_config>
* Linux kernel — Direct Rendering Manager (DRM/KMS) documentation: <https://docs.kernel.org/gpu/drm-uapi.html>
* systemd — `loginctl(1)` and session types: <https://www.freedesktop.org/software/systemd/man/latest/loginctl.html>